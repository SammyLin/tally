# Tally

Tally — self-hosted AI voice notes (renamed from noteapp; D1 `noteapp` / R2 `noteapp-audio` keep the old names). Read `docs/HANDOVER.md` (goals, decisions) and `docs/SPEC.md` (module contracts, schema, API) before changing code.

Layout:
- `web/` — Cloudflare Worker (TypeScript): API, UI (`public/index.html`), D1 migrations. Data lives in D1 + R2, behind Cloudflare Access.
- `runner/` — Go, runs on the Mac: pulls jobs from the Worker, runs ffmpeg / whisper-cli / sherpa-onnx diarization / ACP (local Claude), pushes results back. Config in `runner/.env` (see `.env.example`).

Runner (run from `runner/`):
- Run: `go run .` (= `run`: claim jobs from `API_BASE`, default https://records.3mi.ai). Batch upload: `go run . ingest <folder>`. Models: `go run . models`.
- Local end-to-end: in `web/`, `npx wrangler d1 migrations apply noteapp --local` then `npx wrangler dev --port 8790` (8787 is taken on this Mac; `.dev.vars` has `DEV_NO_AUTH=1`); run the runner with `API_BASE=http://127.0.0.1:8790`.
- Update a Mac's runner (pull, build, install where launchd runs it, models, restart): `runner/deploy.sh`. The UI's runner status shows each runner's build (git commit), flagging older ones.
- Build by hand (binary must not depend on the Go module cache for the sherpa dylibs; never `cp` over a binary macOS has run — it gets SIGKILLed, use a new file + mv):
  ```sh
  mkdir -p lib && cp "$(go list -m -f '{{.Dir}}' github.com/k2-fsa/sherpa-onnx-go-macos)"/lib/aarch64-apple-darwin/lib{sherpa-onnx-c-api,onnxruntime}.dylib lib/ && chmod u+w lib/*
  go build -ldflags '-extldflags "-Wl,-rpath,@executable_path/lib"' -o tally .
  ```
  Ship `tally` together with `lib/`.
