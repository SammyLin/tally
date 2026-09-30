package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

var (
	idleSleep      = 10 * time.Second
	heartbeatEvery = 60 * time.Second // lease is 10 min
	stopGrace      = 30 * time.Second // on SIGINT the current job gets this long before it is failed
	errStopped     = errors.New("runner stopped")
)

// job is a claimed unit of work (POST /api/runner/claim).
type job struct {
	Kind        string `json:"kind"` // recording | summary
	ID          int64  `json:"id"`
	Filename    string `json:"filename"`
	SourceSize  int64  `json:"source_size"`
	RecordingID int64  `json:"recording_id"`
	TemplateID  string `json:"template_id"`
	Language    string `json:"language"`
	Transcript  string `json:"transcript"`
}

type task struct {
	job
	c      *client
	status atomic.Pointer[string]
}

// path is /api/runner/{recordings|summaries}/<id>/<action>.
func (t *task) path(action string) string {
	kind := "recordings"
	if t.Kind == "summary" {
		kind = "summaries"
	}
	return fmt.Sprintf("/api/runner/%s/%d/%s", kind, t.ID, action)
}

func (t *task) post(ctx context.Context, action string, body map[string]any, out any) error {
	body["runner"] = t.c.runner
	return t.c.json(ctx, "POST", t.path(action), body, out)
}

func (t *task) heartbeat(ctx context.Context) error {
	body := map[string]any{}
	if s := t.status.Load(); s != nil {
		body["status"] = *s
	}
	return t.post(ctx, "heartbeat", body, nil)
}

func (t *task) setStatus(ctx context.Context, s string) error {
	t.status.Store(&s)
	return t.heartbeat(ctx)
}

// sttPausedUntil: while Groq's quota is exhausted this runner only claims summaries. Only the run loop goroutine
// (and runJob, which it calls synchronously) touches it.
var sttPausedUntil time.Time

// run claims and processes jobs until ctx is cancelled (SIGINT).
// ponytail: one job at a time; STT saturates the GPU anyway.
func run(ctx context.Context, cfg Config) error {
	c := newClient(cfg)
	if c.id == "" {
		slog.Warn("CF_ACCESS_CLIENT_ID not set; requests will be rejected by Cloudflare Access")
	}
	// work dirs of jobs that crashed here (and finished elsewhere); safe since this process owns DATA_DIR/work
	os.RemoveAll(filepath.Join(cfg.DataDir, "work"))
	slog.Info("runner started", "api", c.base, "runner", c.runner)
	for ctx.Err() == nil {
		var res struct {
			Job *job `json:"job"`
		}
		skip := time.Now().Before(sttPausedUntil)
		err := c.json(ctx, "POST", "/api/runner/claim", map[string]any{"runner": c.runner, "stt": cfg.STTProvider, "skip_recordings": skip}, &res)
		if err != nil && ctx.Err() == nil {
			slog.Error("claim", "err", err)
		}
		if err != nil || res.Job == nil {
			select {
			case <-ctx.Done():
			case <-time.After(idleSleep):
			}
			continue
		}
		runJob(ctx, cfg, c, res.Job)
	}
	return nil
}

// runJob runs one job with a background heartbeat. Lease lost → abort silently; other errors → fail.
// When stop is cancelled the job may finish within stopGrace, else it is cancelled and failed as "runner stopped".
func runJob(stop context.Context, cfg Config, c *client, j *job) {
	t := &task{job: *j, c: c}
	slog.Info("job", "kind", t.Kind, "id", t.ID)
	ctx, cancel := context.WithCancelCause(context.Background())
	defer context.AfterFunc(stop, func() {
		slog.Info("stopping: letting the current job finish", "grace", stopGrace)
		time.AfterFunc(stopGrace, func() { cancel(errStopped) })
	})()

	var wg sync.WaitGroup
	wg.Go(func() {
		tick := time.NewTicker(heartbeatEvery)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
			}
			if err := t.heartbeat(ctx); errors.Is(err, errLeaseLost) {
				cancel(err)
			} else if err != nil && ctx.Err() == nil {
				slog.Warn("heartbeat", "id", t.ID, "err", err)
			}
		}
	})

	var err error
	switch t.Kind {
	case "recording":
		err = safely(func() error { return processRecording(ctx, cfg, t) })
	case "summary":
		err = safely(func() error {
			md, err := summarize(ctx, cfg, t.TemplateID, t.Language, t.Transcript)
			if err != nil {
				return err
			}
			return t.post(ctx, "result", map[string]any{"content_md": md}, nil)
		})
	default:
		err = fmt.Errorf("unknown job kind %q", t.Kind)
	}
	cause := context.Cause(ctx)
	cancel(nil)
	wg.Wait()

	switch {
	case err == nil:
		slog.Info("job done", "kind", t.Kind, "id", t.ID)
		return
	case errors.Is(err, errLeaseLost) || errors.Is(cause, errLeaseLost):
		slog.Warn("lease lost, job aborted", "kind", t.Kind, "id", t.ID)
		return
	}
	if q, ok := errors.AsType[groqQuotaError](err); ok && stop.Err() == nil {
		sttPausedUntil = time.Now().Add(q.wait)
		slog.Warn("groq quota exhausted, requeued", "id", t.ID, "until", sttPausedUntil.Format(time.TimeOnly))
		dctx, dcancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer dcancel()
		derr := t.post(dctx, "defer", map[string]any{"seconds": int(q.wait.Seconds()) + 5, "note": "等待 Groq 免費額度恢復"}, nil)
		if derr == nil {
			return
		}
		slog.Error("requeue", "id", t.ID, "err", derr)
	}
	if stop.Err() != nil { // Ctrl-C also kills ffmpeg/whisper/ACP children, so their errors mean "stopped"
		err = errStopped
	}
	slog.Error("job failed", "kind", t.Kind, "id", t.ID, "err", err)
	fctx, fcancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer fcancel()
	if ferr := t.post(fctx, "fail", map[string]any{"error": err.Error()}, nil); ferr != nil {
		slog.Error("report failure", "id", t.ID, "err", ferr)
	}
}

// safely turns a panic in a job into an error so the runner keeps going.
func safely(f func() error) (err error) {
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("panic: %v", p)
		}
	}()
	return f()
}
