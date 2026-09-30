package main

import (
	"bufio"
	"cmp"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Config is read once at startup from the environment (after loadDotEnv).
type Config struct {
	DataDir      string
	STTProvider  string // "local" or "groq"
	WhisperModel string
	WhisperLang  string // "auto" for detection
	GroqAPIKey   string
	GroqModel    string
	Diarize      bool
	NumSpeakers  int // 0 = auto
	ACPAgent     string

	APIBase            string // Worker origin
	AccessClientID     string // Cloudflare Access service token
	AccessClientSecret string
	RunnerName         string
}

func loadConfig() Config {
	dataDir := cmp.Or(os.Getenv("DATA_DIR"), "data")
	n, _ := strconv.Atoi(os.Getenv("NUM_SPEAKERS"))
	host, _ := os.Hostname()
	return Config{
		DataDir:      dataDir,
		STTProvider:  cmp.Or(os.Getenv("STT_PROVIDER"), "local"),
		WhisperModel: cmp.Or(os.Getenv("WHISPER_MODEL"), filepath.Join(dataDir, "models", "ggml-large-v3-turbo.bin")),
		WhisperLang:  cmp.Or(os.Getenv("WHISPER_LANG"), "zh"),
		GroqAPIKey:   os.Getenv("GROQ_API_KEY"),
		GroqModel:    cmp.Or(os.Getenv("GROQ_MODEL"), "whisper-large-v3"),
		Diarize:      os.Getenv("DIARIZE") != "0",
		NumSpeakers:  n,
		ACPAgent:     cmp.Or(os.Getenv("ACP_AGENT"), "claude-agent-acp"),

		APIBase:            cmp.Or(os.Getenv("API_BASE"), "https://records.3mi.ai"),
		AccessClientID:     os.Getenv("CF_ACCESS_CLIENT_ID"),
		AccessClientSecret: os.Getenv("CF_ACCESS_CLIENT_SECRET"),
		RunnerName:         cmp.Or(os.Getenv("RUNNER_NAME"), host),
	}
}

// loadDotEnv sets KEY=VALUE pairs from path without overriding variables already set.
func loadDotEnv(path string) error {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(strings.TrimPrefix(line, "export "), "=")
		if !ok {
			continue
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		}
		if _, set := os.LookupEnv(k); !set {
			os.Setenv(k, v)
		}
	}
	return sc.Err()
}
