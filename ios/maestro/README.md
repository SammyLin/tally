# Maestro UI flows

Run all flows (in `config.yaml` order) against the booted simulator: `maestro test ios/maestro`

Prerequisites:
1. Local Worker without Access on 8795: in `web/`, `npx wrangler d1 migrations apply noteapp --local --persist-to <dir>`, then
   `npx wrangler dev --port 8795 --ip 127.0.0.1 --local --persist-to <dir> --var DEV_NO_AUTH:1`.
2. Seed everything on a fresh database: `B=http://127.0.0.1:8795 ios/maestro/seed-all.sh <persist-to dir> some-clip.m4a` (≥ 8 s audio).
   It runs `seed.sh` four times: 「會議測試」 (01–05, 12); `TITLE=管理測試 SUMMARY=1` (07–09); `TITLE=知識測試 KNOWLEDGE=1`
   (10–11: people 王小明 / 陳大華 on 知識測試's speakers, a vocabulary suggestion 「iOS」, an answered ask citing 知識測試 and a
   failed one); and `PARITY=1 STATE=<dir>` last (12: a Markdown summary on 「會議測試」, a queued 「排隊測試」, runners marked offline).
   Flows 07–12 change their data (purge, merge, delete person, remove runner), so a second full run needs a fresh database
   (new `--persist-to` dir + `seed-all.sh`).
3. For flow 13, an audio file in the simulator's Files app (我的 iPhone): `ios/maestro/seed-files.sh clip.mp3 [udid]` (saved as 「分享測試.mp3」).
4. Debug build installed: `xcodebuild -scheme Tally -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build` and
   `xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Tally.app`.

Flows: 01 connect · 02 record + upload (language English, checked via the API) · 03 seek · 04 rename speaker · 05 copy as prompt ·
06 Access login · 07 folders (create / subfolder / move / rename / delete) · 08 recording edit (title, move to folder, segment text with the 取消 discard guard,
delete summary, folder name on list rows) · 09 retranscribe with language, trash, trash view, restore, purge ·
10 問問看 (list, ask, delete, retry, answer, citation → 「知識測試」 plays from 00:05) · 11 settings (AI text, language,
vocabulary + suggestion, 我是誰, person rename → merge, unsaved-changes guard, a > 50-character word blocks 儲存, save checked via the API, 「（我）」, delete person).
12 parity (runner header 「沒有 runner 在線」「排隊 1」, no-runner notice, tally:// links to the summary tab / trash / 問問看,
Markdown table / list / quote / code and summary date, 1.75×, speaker bands, transcript range → 「複製這段為 Prompt」,
removing an offline runner). 13 share extension (Files → 分享測試 → 分享 → Kiroku; folder 客戶B, 日本語, title 「分享的錄音」 → 儲存;
Kiroku adopts the inbox entry and uploads it, checked via the API). It taps 儲存 by position: once the keyboard has been up,
Maestro can't see the extension's elements. 14 onboarding (welcome: 「使用 Kiroku Cloud」 / 「連線到自己的伺服器」 / 「兩者差別」; with `-e CLOUD_BACKEND=https://kiroku.3mi.ai` also
註冊 / 登入 and Clerk's sign-up sheet, cancelled — only GET /api/config, never signs up). 01 and 06 reach the URL field through 「連線到自己的伺服器」.
`subflows/open-link.yaml` opens a tally:// link and accepts iOS's 「要在「Kiroku」中打開嗎？」.
`scripts/recording-field.js` reads a recording field from the backend for `assertTrue`.

Options: `-e BACKEND=http://…` (default `http://127.0.0.1:8795`), `-e SHOTS=<dir>` for screenshots (default /tmp), `-e ACCESS_BACKEND=…`
(default `https://records.3mi.ai`; flow 06 only opens its Access login page, never logs in).
After flow 05 the prompt is on the simulator pasteboard: `xcrun simctl pbpaste booted` — it must equal the web's
`buildPrompt` (default options) for the same recording.
Each flow's launch sits in a `retry` block: `simctl launch` can race the previous instance's exit, and Maestro then reports the app as crashed.
