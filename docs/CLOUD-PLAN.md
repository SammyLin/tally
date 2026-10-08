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
