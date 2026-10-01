package main

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Segment is one transcribed span; times in seconds.
type Segment struct {
	Start, End float64
	Text       string
}

// zhPrompt is example text, not an instruction: whisper echoes the prompt verbatim over silence/music,
// and an instruction ("請使用標點符號") then shows up as a subtitle. dropPromptEcho removes such echoes.
const zhPrompt = "好，那我們開始今天的會議。這一季的 roadmap 跟 API 進度，大家有什麼想法？"

func transcribe(ctx context.Context, cfg Config, wavPath string) ([]Segment, error) {
	var segs []Segment
	var err error
	if cfg.STTProvider == "groq" {
		segs, err = transcribeGroq(ctx, cfg, wavPath)
	} else {
		segs, err = transcribeLocal(ctx, cfg, wavPath)
	}
	return dropPromptEcho(segs, sttPrompt(cfg.WhisperLang)), err
}

// dropPromptEcho removes segments whose text is just (part of) the prompt.
func dropPromptEcho(segs []Segment, prompt string) []Segment {
	p := bare(prompt)
	if p == "" {
		return segs
	}
	return slices.DeleteFunc(segs, func(s Segment) bool {
		t := bare(s.Text)
		return utf8.RuneCountInString(t) >= 4 && strings.Contains(p, t)
	})
}

// bare keeps letters and digits only, lowercased.
func bare(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, s)
}

func sttPrompt(lang string) string {
	if lang == "zh" {
		return zhPrompt
	}
	return ""
}

// transcribeLocal runs whisper-cli with token-level JSON and DTW token timestamps, then cuts at sentence ends.
// Segment-level timestamps drift by up to ~15 s after long silence; DTW token times don't.
// VAD is not used: whisper-cli does not map token times back through it and merges sentences across the gaps.
func transcribeLocal(ctx context.Context, cfg Config, wavPath string) ([]Segment, error) {
	dir, err := os.MkdirTemp(filepath.Dir(wavPath), "whisper") // inside work/<id>, so crashed runs get cleaned up
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	out := filepath.Join(dir, "out")
	args := []string{"-m", cfg.WhisperModel, "-f", wavPath, "-l", cfg.WhisperLang, "-np",
		"-t", strconv.Itoa(min(runtime.NumCPU(), 8)), "-ojf", "-of", out}
	if p := sttPrompt(cfg.WhisperLang); p != "" {
		// carrying the prompt into every window keeps output Traditional and cut repetition loops in testing
		args = append(args, "--prompt", p, "--carry-initial-prompt")
	}
	if preset := dtwPreset(cfg.WhisperModel); preset != "" {
		args = append(args, "-dtw", preset, "-nfa") // DTW needs flash attention off
	}
	cmd := exec.CommandContext(ctx, tool("whisper-cli"), args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("whisper-cli: %w: %s", err, tail(stderr.Bytes()))
	}
	data, err := os.ReadFile(out + ".json")
	if err != nil {
		return nil, err
	}
	return parseWhisperJSON(data)
}

// dtwPreset maps ggml-large-v3-turbo[-q5_0].bin to whisper-cli's "large.v3.turbo"; "" if unknown.
func dtwPreset(model string) string {
	name := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(model), "ggml-"), ".bin")
	name, _, _ = strings.Cut(name, "-q")
	name = strings.ReplaceAll(name, "-", ".")
	if slices.Contains([]string{"tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en",
		"large.v1", "large.v2", "large.v3", "large.v3.turbo"}, name) {
		return name
	}
	return ""
}

const dtwLead = 0.2 // seconds

// parseWhisperJSON reads whisper-cli -ojf output and returns one segment per sentence.
func parseWhisperJSON(data []byte) ([]Segment, error) {
	var r struct {
		Transcription []struct {
			Offsets struct{ From, To int }
			Tokens  []struct {
				Text    string
				Offsets struct{ From, To int }
				TDTW    int `json:"t_dtw"`
			}
		}
	}
	if err := json.Unmarshal(protectInvalid(data), &r); err != nil {
		return nil, fmt.Errorf("whisper json: %w", err)
	}
	var segs []Segment
	for _, s := range r.Transcription {
		var text strings.Builder
		start, first := -1.0, true
		emit := func(end float64) {
			t := strings.TrimSpace(restoreInvalid(text.String()))
			// whisper sometimes ends a window mid-sentence ("新的報告。" + next window "表功能。");
			// a short opening fragment overlapping the previous sentence is its continuation
			if n := len(segs); first && t != "" && n > 0 && start < segs[n-1].End && utf8.RuneCountInString(t) <= 4 {
				segs[n-1].Text = strings.TrimRight(segs[n-1].Text, sentenceEnd) + t
				segs[n-1].End = max(segs[n-1].End, end)
			} else if t != "" {
				segs = append(segs, Segment{start, max(end, start+0.01), t})
			}
			text.Reset()
			start, first = -1, false
		}
		for _, tok := range s.Tokens {
			if strings.HasPrefix(tok.Text, "[_") { // [_BEG_], [_TT_123], ...
				continue
			}
			from, to := float64(tok.Offsets.From)/1000, float64(tok.Offsets.To)/1000
			if tok.TDTW >= 0 { // centiseconds; measured ~0.1-0.45 s late on sentence starts, so lead a little
				from, to = max(float64(tok.TDTW)/100-dtwLead, 0), float64(tok.TDTW)/100
			}
			if start < 0 {
				start = from
			}
			text.WriteString(tok.Text)
			if strings.ContainsAny(tok.Text, sentenceEnd) {
				emit(to)
			}
		}
		if text.Len() > 0 {
			emit(float64(s.Offsets.To) / 1000)
		}
	}
	return segs, nil
}

// whisper-cli writes each token's raw bytes, so a CJK rune split across tokens is invalid UTF-8 in the JSON.
// encoding/json would turn those bytes into U+FFFD; park them in U+F780..U+F7FF and restore after joining tokens.
func protectInvalid(b []byte) []byte {
	if utf8.Valid(b) {
		return b
	}
	out := make([]byte, 0, len(b)+16)
	for len(b) > 0 {
		r, n := utf8.DecodeRune(b)
		if r == utf8.RuneError && n == 1 {
			out = utf8.AppendRune(out, 0xF700+rune(b[0]))
		} else {
			out = append(out, b[:n]...)
		}
		b = b[n:]
	}
	return out
}

func restoreInvalid(s string) string {
	out := make([]byte, 0, len(s))
	for _, r := range s {
		if r >= 0xF780 && r <= 0xF7FF {
			out = append(out, byte(r-0xF700))
		} else {
			out = utf8.AppendRune(out, r)
		}
	}
	return strings.ToValidUTF8(string(out), "")
}

var groqURL = "https://api.groq.com/openai/v1/audio/transcriptions"

// groqQuotaError: Groq asked us to wait longer than groqMaxWait (the free tier caps audio seconds per hour
// and per day). The runner puts the recording back in the queue until then instead of blocking.
type groqQuotaError struct{ wait time.Duration }

func (e groqQuotaError) Error() string {
	return fmt.Sprintf("groq quota exhausted, retry after %s", e.wait)
}

const groqMaxWait = time.Minute

const groqChunkSec = 600 // 10 min of 16k mono FLAC is well under Groq's 25 MB limit

func transcribeGroq(ctx context.Context, cfg Config, wavPath string) ([]Segment, error) {
	if cfg.GroqAPIKey == "" {
		return nil, errors.New("GROQ_API_KEY is not set")
	}
	dir, err := os.MkdirTemp(filepath.Dir(wavPath), "groq")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	cmd := exec.CommandContext(ctx, tool("ffmpeg"), "-nostdin", "-loglevel", "error", "-i", wavPath,
		"-ar", "16000", "-ac", "1", "-c:a", "flac", "-f", "segment", "-segment_time", strconv.Itoa(groqChunkSec),
		filepath.Join(dir, "%04d.flac"))
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("ffmpeg split: %w: %s", err, tail(out))
	}
	var segs []Segment
	offset := 0.0
	for _, c := range groqChunks(dir) {
		got, dur, err := groqChunk(ctx, cfg, c)
		if err != nil {
			return nil, fmt.Errorf("groq %s: %w", filepath.Base(c), err)
		}
		for _, s := range got {
			segs = append(segs, Segment{s.Start + offset, s.End + offset, s.Text})
		}
		offset += cmp.Or(dur, groqChunkSec) // the segment muxer cuts on packet boundaries; trust the reported duration
	}
	return segs, nil
}

// groqChunks lists the ffmpeg segment files in order. Only ffmpeg's own NNNN.flac names count: on exFAT/SMB
// volumes macOS adds AppleDouble "._0000.flac" files next to them, which "*.flac" would pick up (and sort first).
func groqChunks(dir string) []string {
	chunks, _ := filepath.Glob(filepath.Join(dir, "[0-9][0-9][0-9][0-9].flac")) // sorted; names are zero-padded
	return chunks
}

type groqSegment struct {
	Start, End       float64
	Text             string
	AvgLogprob       float64 `json:"avg_logprob"`
	CompressionRatio float64 `json:"compression_ratio"`
	NoSpeechProb     float64 `json:"no_speech_prob"`
}

// hallucinated applies Whisper's own thresholds: silence the model is unsure about, or a repetition loop.
func (g groqSegment) hallucinated() bool {
	return (g.NoSpeechProb > 0.6 && g.AvgLogprob < -1) || g.CompressionRatio > 2.4
}

func groqChunk(ctx context.Context, cfg Config, path string) ([]Segment, float64, error) {
	audio, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, err
	}
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, _ := mw.CreateFormFile("file", filepath.Base(path))
	fw.Write(audio)
	mw.WriteField("model", cfg.GroqModel)
	mw.WriteField("response_format", "verbose_json")
	mw.WriteField("timestamp_granularities[]", "segment")
	mw.WriteField("temperature", "0")
	if cfg.WhisperLang != "auto" {
		mw.WriteField("language", cfg.WhisperLang)
	}
	if p := sttPrompt(cfg.WhisperLang); p != "" {
		mw.WriteField("prompt", p)
	}
	mw.Close()

	const attempts = 6
	for i := range attempts {
		req, _ := http.NewRequestWithContext(ctx, "POST", groqURL, bytes.NewReader(body.Bytes()))
		req.Header.Set("Authorization", "Bearer "+cfg.GroqAPIKey)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		resp, err := http.DefaultClient.Do(req)
		var wait time.Duration
		if err == nil {
			data, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				var r struct {
					Duration float64
					Segments []groqSegment
				}
				if err := json.Unmarshal(data, &r); err != nil {
					return nil, 0, err
				}
				var segs []Segment
				for _, g := range r.Segments {
					if t := strings.TrimSpace(g.Text); t != "" && g.End > g.Start && !g.hallucinated() {
						segs = append(segs, Segment{g.Start, g.End, t})
					}
				}
				return segs, r.Duration, nil
			}
			err = fmt.Errorf("HTTP %d: %s", resp.StatusCode, tail(data))
			if resp.StatusCode != http.StatusTooManyRequests && resp.StatusCode < 500 {
				return nil, 0, err
			}
			if s, perr := strconv.ParseFloat(resp.Header.Get("Retry-After"), 64); perr == nil {
				wait = time.Duration(s * float64(time.Second))
			}
			if resp.StatusCode == http.StatusTooManyRequests && wait > groqMaxWait {
				return nil, 0, groqQuotaError{wait}
			}
		}
		if ctx.Err() != nil || i == attempts-1 {
			return nil, 0, err
		}
		wait = min(max(wait, time.Second<<i), 2*time.Minute)
		slog.Warn("groq retry", "err", err, "wait", wait)
		select {
		case <-ctx.Done():
			return nil, 0, ctx.Err()
		case <-time.After(wait):
		}
	}
	panic("unreachable")
}
