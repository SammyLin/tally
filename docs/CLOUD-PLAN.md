# Kiroku Cloud plan (draft 2026-10-09)

Goal: offer **Kiroku Cloud** (paid, multi-user, hosted processing) next to the existing **self-hosted** setup. One codebase; the Worker runs in either mode.

## Decisions (user, 2026-10-09)

| Topic | Decision |
|---|---|
| Login | **Clerk** (Google / Apple / email). Personal accounts only for now; tables get an `org_id` column reserved for teams + enterprise SSO later. |
| Payments | **Taiwan payment provider** (ECPay or TapPay) on the web. iOS must also offer **Apple In-App Purchase** for the same plans (App Store guideline 3.1.1 / 3.1.3(b)); both feed one entitlement record per user. |
| Pricing | **Monthly subscription + minutes quota** (e.g. Free / Pro / Unlimited — numbers TBD). |
| Cloud processing | **Groq** (speech-to-text, paid tier) + **Claude API** (cleanup, titles, summaries, Ask) running on Cloudflare; no dependency on the owner's Macs. |

## Modes

`AUTH_MODE` Worker var:
- `access` (default, today): single user behind Cloudflare Access; Mac runners via service tokens. Self-host docs unchanged.
- `clerk`: Kiroku Cloud. Every request carries a Clerk session JWT (web cookie / iOS SDK bearer); Worker verifies it networklessly with Clerk's JWKS and resolves `user_id`.

## Phases

### Phase 1 — Accounts and data isolation
- Clerk app (dev + prod instances); web sign-in/up pages; iOS: Clerk iOS SDK (`clerk-ios`) behind the existing "connect to backend" screen — Cloud preset uses Clerk, a custom URL keeps today's Access flow.
- D1 migration: `users(id, clerk_id, email, plan, created_at)`, and `user_id` (+ nullable `org_id`) on recordings, folders, speakers, people, voiceprints, summaries, asks, settings, vocabulary, runners; every query scoped by `user_id` (one helper, enforced in tests: a second user can never read/write the first user's rows; R2 keys prefixed `u/<user_id>/`).
- Self-host (`access` mode) uses a single implicit user so nothing changes for existing data.

### Phase 2 — Cloud processing
- Cloudflare Queues: upload complete → job message.
- Speech-to-text: Groq Whisper (verbose_json) from a Worker/Container consumer, same chunking + cache logic as the runner.
- Speaker diarization + voiceprints: Cloudflare Containers running the existing Go pipeline (sherpa-onnx Linux build) — or a hosted diarization API if Containers cost too much; decide after a cost test.
- Cleanup / title / summary / Ask: Claude API (Anthropic SDK) instead of local ACP; prompts reused from runner/pipeline.go.
- Mac runners stay supported for self-host; Cloud users never touch them.

### Phase 3 — Billing and quotas
- `plans` (Free / Pro / Unlimited, minutes per month), `subscriptions` (provider: ecpay|tappay|apple, status, period end), `usage_minutes` ledger (debit on processing start, refund on failure).
- Quota check before a job is claimed; UI shows "N 分鐘剩餘" like Plaud.
- **Web: ECPay recommended** — native 定期定額 recurring card billing and built-in 電子發票 (Taiwan B2C must issue e-invoices). TapPay is the alternative (card tokens + our own renewal scheduler; e-invoice via a separate provider).
- **iOS: StoreKit 2** subscriptions with the same plan ids; App Store Server Notifications v2 → Worker webhook → same `subscriptions` table. Restore purchases; manage subscription link.
- Webhooks are idempotent and verified (ECPay CheckMacValue, Apple JWS).

### Phase 4 — Launch hygiene
- Landing page, pricing page, Terms, Privacy (audio is personal data: retention, deletion, export), account deletion (App Store requirement), data export.
- Abuse limits (upload size/rate), monitoring and cost alerts (Groq / Claude / Containers spend per user).

## What the owner needs to provide

| Item | For |
|---|---|
| Clerk account: application (dev + prod), Apple + Google sign-in enabled | Phase 1 |
| Anthropic API key (Claude) and Groq paid plan key | Phase 2 |
| ECPay merchant account (or TapPay) with 定期定額 + 電子發票 enabled; test credentials | Phase 3 |
| App Store Connect: Paid Applications agreement, bank/tax info, subscription group + products | Phase 3 |
| Prices and minute quotas per plan; Terms/Privacy owner details | Phase 3–4 |

## Open questions
- Exact plan prices and minutes.
- ECPay vs TapPay (recommendation: ECPay for recurring + e-invoice).
- Data region / retention promise for Cloud users.
- Whether Cloud users can still attach their own Mac runner ("bring your own compute") — possible later via per-user runner tokens.

## Kiroku Cloud — Phase 1 (accounts + isolation)

Contract for the `kiroku-cloud-auth` branch. Self-host (`AUTH_MODE=access`) must behave exactly as today; everything below is additive.

### Deployment
- New wrangler environment `cloud` in `web/wrangler.jsonc`: Worker `kiroku-cloud`, custom domain `kiroku.3mi.ai`, D1 `kiroku_cloud`, R2 `kiroku-cloud-audio`, `vars.AUTH_MODE="clerk"`. The top-level config (production self-host at records.3mi.ai, D1 `noteapp`, R2 `noteapp-audio`) is not touched or redeployed by this phase.
- Vars (cloud): `AUTH_MODE`, `CLERK_PUBLISHABLE_KEY`, `CLERK_AUTHORIZED_PARTIES` (comma list; deployed: `https://kiroku.3mi.ai` only, local dev adds `http://localhost:8800,http://127.0.0.1:8800` in `.dev.vars.cloud`). Secrets: `CLERK_SECRET_KEY`, `RUNNER_TOKEN`. Local dev: `wrangler dev --env cloud --port 8800`, secrets in `.dev.vars.cloud` (never committed, never printed).

### Auth (`AUTH_MODE`)
- `access` (default, var unset): unchanged — Access JWT, `DEV_NO_AUTH=1` for local dev, every request is user id **1**; `/api/runner/*` keeps accepting Access service tokens.
- `clerk`: `src/auth.ts` gains `verifyClerkJwt` reusing the existing RS256/JWKS code (no new runtime dependency). JWKS from `https://<frontend-api>/.well-known/jwks.json` (frontend API host = base64-decoded publishable key, minus the trailing `$`); checks `exp`/`nbf`, `iss === https://<frontend-api>`, and `azp` ∈ `CLERK_AUTHORIZED_PARTIES` when `azp` is present (native iOS tokens may omit it). Token source: `Authorization: Bearer <jwt>`, else the `__session` cookie (needed for `/media/<id>`, which `<audio>` fetches without headers). `DEV_NO_AUTH` is ignored in clerk mode.
- `sub` (Clerk user id) → `users.id`: `INSERT INTO users(clerk_id) VALUES(?) ON CONFLICT(clerk_id) DO NOTHING`, then select the id; cached per isolate in a `Map`. On a fresh insert, the email is filled from `GET https://api.clerk.com/v1/users/<sub>` with `CLERK_SECRET_KEY` (failure → email stays NULL and is retried next time it is NULL).
- Route classes in clerk mode, fail closed:
  - `/api/runner/*` → only `Authorization: Bearer <RUNNER_TOKEN>` (constant-time compare). A Clerk token gets 403.
  - Every other `/api/*` and `/media/*` → only a valid Clerk token. The runner token gets 401.
  - `GET /api/config` → public in both modes: `{auth_mode, clerk_publishable_key, app_name: "Kiroku"}` (`clerk_publishable_key` is null in access mode).
- `denied()` in `index.ts` becomes `identify(req, env)` → `{uid}` | `{runner: true}` | error `Response`. User handlers get `uid` as their 6th argument `(req, env, match, url, ctx, uid)`. **Scoping rule: every SQL statement in a user handler binds `uid` (`... AND user_id=?`). A row with the wrong owner is reported as 404, never 403.**
- The existing CSRF check (Sec-Fetch-Site) stays. `__session` is SameSite=Lax, and every non-GET request goes through that check.

### Schema (`web/migrations/0011_users.sql`, one file, must be safe on the live self-host DB)
- `users(id INTEGER PRIMARY KEY AUTOINCREMENT, clerk_id TEXT UNIQUE, email TEXT, plan TEXT NOT NULL DEFAULT 'free', created_at TEXT NOT NULL DEFAULT (datetime('now')))`, seeded with `id=1, clerk_id NULL` (the self-host user). Cloud users therefore start at 2, so a row that forgets to set `user_id` (defaults to 1) ends up orphaned and is never shown to another user.
- `user_id INTEGER NOT NULL DEFAULT 1 REFERENCES users(id)` and `org_id INTEGER` (NULL, reserved) on **every table except `runners`**: `recordings, folders, speakers, segments, people, voiceprints, summaries, asks, settings, push_subscriptions, vocab_scans, vocab_suggestions`. Denormalized on child tables (speakers, segments, summaries, voiceprints) so each route checks ownership with `WHERE id=? AND user_id=?` and needs no joins.
- Uniqueness changes to per-user:
  - `folders_name` → `(user_id, coalesce(parent_id,0), name)`
  - `people.name UNIQUE` → `UNIQUE(user_id, name)` (table rebuild)
  - `settings` PK `key` → `PRIMARY KEY(user_id, key)` (rebuild)
  - `vocab_suggestions` PK `term` → `PRIMARY KEY(user_id, term)` (rebuild)
  - `push_subscriptions` keeps PK `endpoint`; subscribing upserts `user_id`, so a shared browser follows whoever signed in last.
  - `voiceprints.speaker_id UNIQUE` stays (speaker ids are global).
- Rebuild trap: in D1, `DROP TABLE people` performs an implicit DELETE that fires FK actions. That would cascade-delete `voiceprints` and null `speakers.person_id` / `suggest_person_id`. The migration stashes those columns in temp tables before the drop and restores them after the rename. `web/test/migrate.sh` applies 0011 to a local copy holding self-host-shaped data and asserts that the row counts of every table and the non-NULL person links are unchanged.
- Indexes: `(user_id, created_at)` on recordings; `(user_id, …)` replacing the per-table lookups that list things (recordings by folder/status/filename, asks, summaries, people, vocab_suggestions by status).
- `runners` stays global: shared internal infrastructure until Phase 2.

### Runners in clerk mode
- They process every user's jobs. Claim order stays global (oldest first). `ponytail: no per-user fairness; one heavy user can delay others until Phase 2 queues`.
- Every runner route loads the job row and acts on **that row's `user_id`**: the claim payload carries that user's `settings` (stt_lang, cleanup, vocab, about, me…), and every derived write and read uses the job's user. This covers transcript/speakers/segments inserts, people/voiceprint creation, voiceprint **matching and suggestions** (`voice.ts` only compares voiceprints with the same `user_id`; `auto_label` is read from that user's settings), **rematch**, **Ask retrieval** (`/api/runner/asks/<id>/transcripts` only searches recordings of the ask's user), **vocab scans** (the from_id..to_id range only covers that user's recordings; suggestions are upserted under that user), and Web Push (only that user's subscriptions).
- User-facing `GET /api/runners` in clerk mode returns one synthetic entry `{name: "Kiroku Cloud", online, last_seen}` aggregated over all runners. Queue counts and "current job" only cover the caller's own jobs. `DELETE /api/runners/<name>` → 403.
- The runner gets `RUNNER_TOKEN` (new env `RUNNER_TOKEN`, sent as `Authorization: Bearer`) in addition to today's CF Access headers, so the same binary serves both deployments.

### R2
- New objects: `u/<user_id>/rec/<id>/source.<ext>` and `u/<user_id>/rec/<id>/play.m4a` (both modes). Readers keep using `source_key`/`play_key` from the row, so existing `rec/<id>/…` objects keep working untouched.

### IDOR suite (`web/test/idor.test.ts`)
- `index.ts` exports `routes`. The test asserts that every route regex is listed in its own coverage table, so a new route fails the test until someone adds a case for it.
- Runs against `wrangler dev --env cloud --port 8801` on a fresh local D1, with two real Clerk dev users (`clerk users` creates them; session tokens are minted through the Backend API from `CLERK_SECRET_KEY`, so the real verification path is used and there is no test-only auth bypass). User A creates one of everything: folder, upload → recording (the runner token drives transcript + speaker-embeddings + done), summary, ask, person, settings, push subscription, vocab suggestion. Then for **every** user route, user B, given A's ids:
  - GET returns 404, or a list without A's rows
  - PATCH/DELETE/POST return 404 and change nothing (A re-reads to confirm)
  - `/media/<A's id>` returns 404
- It also asserts that a runner-token request to a user route and a Clerk-token request to a runner route are both rejected, and that a voiceprint enrolled by A is never matched or suggested to B's recording.

### Web (`public/index.html`, keep the diff structural; styling belongs to the rebrand branch)
- On boot, `fetch('/api/config')`. In `access` mode nothing changes.
- In `clerk` mode, load `https://cdn.jsdelivr.net/npm/@clerk/clerk-js@6.38.1/dist/clerk.browser.js` (pinned) and run `Clerk.load()`.
  - Signed out: a minimal landing page (Kiroku 記錄 wordmark, one sentence, 登入 / 註冊 buttons → `Clerk.openSignIn()` / `openSignUp()`). The app shell is not rendered.
  - Signed in: `Clerk.mountUserButton()` in the header; sign-out returns to the landing page.
- The single fetch wrapper (`index.html` ~line 643) adds `Authorization: Bearer ${await Clerk.session.getToken()}`. A 401 response sends the user back to the landing page.

### iOS
- Connect screen: a new **Kiroku Cloud** button that sets the backend to `https://kiroku.3mi.ai` and signs in with `clerk-ios` (SPM `github.com/clerk/clerk-ios`, pinned `1.6.1`, `AuthView`: email code; Apple/Google appear only if enabled in the Clerk instance). The publishable key comes from that backend's `/api/config`.
- `API.swift` header building: in cloud mode, send `Authorization: Bearer <Clerk.shared.session.getToken()>`, fetched per request (the SDK caches and refreshes it). The custom-URL path (LoginView / `cf-access-token`) is unchanged.
- Log out calls `Clerk.shared.signOut()` and clears the stored backend mode. The upload queue keeps working while signed in because tokens are fetched per request.

### Done when
The self-host tests pass unchanged, `idor.test.ts` passes, the migration test passes, `kiroku-cloud` is deployed at kiroku.3mi.ai, two accounts can each sign in on web and iOS, and neither sees the other's data.
