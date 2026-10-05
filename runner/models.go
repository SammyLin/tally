package main

import (
	"archive/tar"
	"compress/bzip2"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"time"
)

const whisperModelURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"

// downloadModels fetches missing models; existing files are left alone.
func downloadModels(ctx context.Context, cfg Config) error {
	if err := fetch(ctx, whisperModelURL, cfg.WhisperModel, nil); err != nil {
		return err
	}
	if err := fetch(ctx, embModelURL, embModelPath(cfg), nil); err != nil {
		return err
	}
	if err := fetch(ctx, voiceModelURL, voiceModelPath(cfg), nil); err != nil {
		return err
	}
	return fetch(ctx, segModelURL, segModelPath(cfg), untarFile("model.onnx"))
}

// fetch downloads url into dst via a tmp file + rename; extract, if set, turns the body into the file content.
func fetch(ctx context.Context, url, dst string, extract func(io.Reader) (io.Reader, error)) error {
	if _, err := os.Stat(dst); err == nil {
		slog.Info("model present", "path", dst)
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	slog.Info("downloading", "url", url, "mb", resp.ContentLength>>20)
	var body io.Reader = &progress{r: resp.Body, total: resp.ContentLength, name: filepath.Base(dst), last: time.Now()}
	if extract != nil {
		if body, err = extract(body); err != nil {
			return fmt.Errorf("%s: %w", url, err)
		}
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), filepath.Base(dst)+".*.part")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = io.Copy(tmp, body)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return fmt.Errorf("download %s: %w", url, err)
	}
	if err := os.Rename(tmp.Name(), dst); err != nil {
		return err
	}
	slog.Info("model saved", "path", dst)
	return nil
}

// untarFile returns an extractor yielding the entry named base from a .tar.bz2 stream.
func untarFile(base string) func(io.Reader) (io.Reader, error) {
	return func(r io.Reader) (io.Reader, error) {
		tr := tar.NewReader(bzip2.NewReader(r))
		for {
			h, err := tr.Next()
			if errors.Is(err, io.EOF) {
				return nil, fmt.Errorf("%s not in archive", base)
			}
			if err != nil {
				return nil, err
			}
			if h.Typeflag == tar.TypeReg && path.Base(h.Name) == base {
				return tr, nil
			}
		}
	}
}

type progress struct {
	r        io.Reader
	n, total int64
	name     string
	last     time.Time
}

func (p *progress) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.n += int64(n)
	if time.Since(p.last) > 5*time.Second {
		p.last = time.Now()
		slog.Info("downloading", "file", p.name, "mb", p.n>>20, "of_mb", p.total>>20)
	}
	return n, err
}
