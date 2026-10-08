# Maestro UI flows

Run all flows (in `config.yaml` order) against the booted simulator: `maestro test ios/maestro`

Prerequisites:
1. Local Worker without Access on 8795: in `web/`, `npx wrangler d1 migrations apply noteapp --local --persist-to <dir>`, then
   `npx wrangler dev --port 8795 --ip 127.0.0.1 --local --persist-to <dir> --var DEV_NO_AUTH:1`.
2. Seed a processed recording 「會議測試」 (≥ 8 s audio): `ios/maestro/seed.sh some-clip.m4a`.
3. Debug build installed: `xcodebuild -scheme Tally -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build` and
   `xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Tally.app`.

Options: `-e BACKEND=http://…` (default `http://127.0.0.1:8795`), `-e SHOTS=<dir>` for screenshots (default /tmp), `-e ACCESS_BACKEND=…`
(default `https://records.3mi.ai`; flow 06 only opens its Access login page, never logs in).
After flow 05 the prompt is on the simulator pasteboard: `xcrun simctl pbpaste booted` — it must equal the web's
`buildPrompt` (default options) for the same recording.
