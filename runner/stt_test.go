package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestParseWhisperJSON(t *testing.T) {
	yi := "議" // 3 bytes, split across two tokens like whisper-cli does
	data := []byte(`{"transcription":[{"offsets":{"from":0,"to":9000},"text":"x","tokens":[
		{"text":"[_BEG_]","offsets":{"from":0,"to":0},"t_dtw":-1},
		{"text":"會","offsets":{"from":100,"to":300},"t_dtw":150},
		{"text":"` + yi[:2] + `","offsets":{"from":300,"to":400},"t_dtw":170},
		{"text":"` + yi[2:] + `。","offsets":{"from":400,"to":500},"t_dtw":190},
		{"text":" OK","offsets":{"from":600,"to":700},"t_dtw":-1},
		{"text":"嗎","offsets":{"from":700,"to":800},"t_dtw":-1},
		{"text":"[_TT_450]","offsets":{"from":9000,"to":9000},"t_dtw":-1}]},
		{"offsets":{"from":9000,"to":9900},"text":"x","tokens":[
		{"text":"了","offsets":{"from":9000,"to":9100},"t_dtw":895},
		{"text":"。","offsets":{"from":9100,"to":9200},"t_dtw":910}]}]}`)
	got, err := parseWhisperJSON(data)
	if err != nil {
		t.Fatal(err)
	}
	want := []Segment{{1.3, 1.9, "會議。"}, {0.6, 9.1, "OK嗎了。"}} // "了。" continues the previous window
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestTranscribeGroq(t *testing.T) {
	wav := filepath.Join(t.TempDir(), "a.wav") // 11 min of silence -> 2 chunks
	if out, err := exec.Command("ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
		"-t", "660", "-c:a", "pcm_s16le", wav).CombinedOutput(); err != nil {
		t.Skip("ffmpeg:", err, string(out))
	}
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.Header().Set("Retry-After", "0")
			http.Error(w, "slow down", http.StatusTooManyRequests)
			return
		}
		f, _, err := r.FormFile("file")
		if err != nil {
			t.Error(err)
			return
		}
		b, _ := io.ReadAll(f)
		if d := flacDuration(t, b); d != "600" && d != "60" { // each chunk's own length, not N/A or the whole file's
			t.Errorf("chunk header duration %q", d)
		}
		if string(b[:4]) != "fLaC" || r.Header.Get("Authorization") != "Bearer k" ||
			r.FormValue("model") != "whisper-large-v3" || r.FormValue("language") != "zh" ||
			r.FormValue("prompt") != zhPrompt || r.FormValue("response_format") != "verbose_json" ||
			r.FormValue("temperature") != "0" {
			t.Errorf("bad request: %v", r.MultipartForm.Value)
		}
		dur := 600.0
		if calls == 3 {
			dur = 60
		}
		fmt.Fprintf(w, `{"duration":%v,"segments":[{"start":1,"end":2.5,"text":" 你好。"},{"start":3,"end":3,"text":""}]}`, dur)
	}))
	defer srv.Close()
	groqURL = srv.URL
	cfg := Config{GroqAPIKey: "k", GroqModel: "whisper-large-v3", WhisperLang: "zh", DataDir: t.TempDir()}
	got, err := transcribeGroq(t.Context(), cfg, wav)
	if err != nil {
		t.Fatal(err)
	}
	want := []Segment{{1, 2.5, "你好。"}, {601, 602.5, "你好。"}}
	if fmt.Sprint(got) != fmt.Sprint(want) || calls != 3 {
		t.Fatalf("got %v (calls %d) want %v", got, calls, want)
	}

	// quota hit on chunk 2: the retry must only send chunk 2 again
	calls = 0
	quota := true
	srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 2 && quota {
			w.Header().Set("Retry-After", "116")
			http.Error(w, "quota", http.StatusTooManyRequests)
			return
		}
		fmt.Fprint(w, `{"duration":1,"segments":[{"start":1,"end":2,"text":"好。"}]}`)
	})
	if _, err := transcribeGroq(t.Context(), cfg, wav); err == nil {
		t.Fatal("want quota error")
	}
	calls, quota = 0, false
	if got, err = transcribeGroq(t.Context(), cfg, wav); err != nil || calls != 1 || len(got) != 2 {
		t.Fatalf("resume: got %v err %v calls %d, want 2 segments from 1 call", got, err, calls)
	}
	if left, _ := filepath.Glob(filepath.Join(cfg.DataDir, "groq-cache", "*")); len(left) != 0 {
		t.Fatalf("cache not cleaned: %v", left)
	}
}

// flacDuration is what ffprobe (and Groq's billing) reads from the FLAC header.
func flacDuration(t *testing.T, b []byte) string {
	f := filepath.Join(t.TempDir(), "c.flac")
	os.WriteFile(f, b, 0o600)
	out, _ := exec.Command("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f).Output()
	d, _, _ := strings.Cut(strings.TrimSpace(string(out)), ".")
	return d
}

func TestDropPromptEcho(t *testing.T) {
	segs := []Segment{{0, 1, "大家好。"}, {1, 2, "那我們開始今天的會議。"}, {2, 3, "這一季的 Roadmap 跟 API 進度，"}, {3, 4, "好。"}, {4, 5, "我們開始吧。"}}
	got := dropPromptEcho(segs, zhPrompt)
	var texts []string
	for _, s := range got {
		texts = append(texts, s.Text)
	}
	if want := []string{"大家好。", "好。", "我們開始吧。"}; !slices.Equal(texts, want) {
		t.Fatalf("got %q, want %q", texts, want)
	}
	if g := (groqSegment{NoSpeechProb: 0.9, AvgLogprob: -1.5}); !g.hallucinated() {
		t.Fatal("silence not dropped")
	}
	if g := (groqSegment{NoSpeechProb: 0.9, AvgLogprob: -0.2}); g.hallucinated() {
		t.Fatal("confident speech dropped")
	}
}

func TestGroqQuota(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "116")
		http.Error(w, "rate limit", http.StatusTooManyRequests)
	}))
	defer srv.Close()
	old := groqURL
	groqURL = srv.URL
	defer func() { groqURL = old }()
	f := filepath.Join(t.TempDir(), "a.flac")
	os.WriteFile(f, []byte("x"), 0o600)
	if _, _, err := groqChunk(t.Context(), Config{GroqAPIKey: "k", GroqModel: "m", WhisperLang: "zh"}, f); err == nil {
		t.Fatal("want groqQuotaError")
	} else if q, ok := errors.AsType[groqQuotaError](err); !ok || q.wait != 116*time.Second {
		t.Fatalf("got %v, want groqQuotaError{116s}", err)
	}
}
