# Tally for iOS

SwiftUI app (iOS 17+; one dependency, Clerk's `clerk-ios` 1.6.1 via SPM for Kiroku Cloud sign-in) for the Tally backend. Features (same API as the web front end):

- **Record**: keeps recording in the background and with the screen locked. You choose a title, folder and transcription language when you save.
- **Upload queue**: multipart uploads in 50 MiB parts, retried until they succeed. Queued items can be deleted (asks first). You can also import audio/video files with a chosen language.
- **Library**: 最近 / 全部 / 未分類 / 垃圾桶 and folders (create, subfolder, rename, move, delete), search, and a runner status header (online, queue size, remove offline runners).
- **Recording detail**: play and seek (up to 1.75×), speaker bands and legend, rename or merge speakers, confirm or reject a suggested speaker, edit a transcript line (asks before discarding edits), rename, move, retranscribe with a language, trash / restore / purge.
- **Summary**: Markdown rendering, delete. **Copy as prompt** uses the same format as the web's `buildPrompt`, for a whole recording or a selected range.
- **問問看**: ask questions across recordings, answers cite recordings and jump to that time. Retry or delete questions.
- **Settings**: AI text, default language, vocabulary (with suggestions and a 50-character limit; a rejected word keeps the sheet open), 我是誰, rename / merge / delete people, and change backend. Unsaved changes are guarded.
- **`tally://` links**: see Links below.
- **存到 Kiroku (share sheet)**: share audio or video (MP3, M4A, WAV, videos; up to 20 files) from Voice Memos, Files, LINE, Mail and so on, and pick **Kiroku**. You can set the title, folder and language, then tap 儲存. The extension only copies the files into the App Group; the app queues them for upload the next time it opens or comes to the foreground. See Share extension below.

## Build and run

`Tally.xcodeproj` is generated from `project.yml` and is not committed:

```sh
cd ios
/opt/homebrew/bin/xcodegen
open Tally.xcodeproj                      # or build from the command line:
xcodebuild -scheme Tally -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Tally.app
```

## Tests

Unit tests (Swift Testing, `TallyTests/`: prompt format, upload parts and backoff, Access login, library, knowledge, parity, share inbox adoption):

```sh
cd ios && /opt/homebrew/bin/xcodegen
xcodebuild test -scheme Tally -destination 'platform=iOS Simulator,name=iPhone 17'
```

On first launch the app asks for the backend URL (default `https://records.3mi.ai`). For a local Worker, use `http://127.0.0.1:<port>`. Plain http is allowed only for local and LAN addresses.

### Maestro UI tests

`maestro test ios/maestro -e BACKEND=http://127.0.0.1:<port>` runs all 13 flows in `ios/maestro` against the booted simulator. They need a local Worker without Access, a freshly seeded database (`ios/maestro/seed-all.sh`) and a Debug build installed, plus an audio file in the Files app for flow 13 (`ios/maestro/seed-files.sh clip.mp3`). Flows 07–13 change their data, so each full run needs a fresh database. See [maestro/README.md](maestro/README.md) for setup steps and the `-e BACKEND=… -e SHOTS=…` options.

## Links

`tally://` opens the app at the same places as the web's hash routes: `tally://recent|all|unfiled|trash|folder/<id>`, optionally
followed by `/rec/<id>[/summary]` (or just `tally://rec/<id>[/summary][?ms=<ms>]`), and `tally://ask[/<id>]`. Detail ⋯ →
「複製連結」 copies one. Links wait while a recording or the settings sheet is open.

## Share extension

The `KirokuShare` target (bundle ID `ai.3mi.tally.share`, embedded in the app) shows up in the share sheet for any audio or movie attachment. It hands files to the app through the App Group `group.ai.3mi.tally` (`Shared/Inbox.swift`, compiled into both targets):

- The extension copies each file into `Inbox/.tmp-<uuid>/<original name>` as soon as it opens (this streams, so big files are fine). On 儲存 it writes `meta.json` (`{title, folder_id, language, created_at}`) and renames the folder to `Inbox/<uuid>/`. A folder without the `.tmp-` prefix is therefore always complete. 取消 deletes the copies. A killed extension's `.tmp-` folders are removed after a day.
- The extension never uploads, because share extensions have tight memory and time limits. iOS doesn't let a share extension open its app, so the confirmation says 「已存到 Kiroku，開啟 App 後會上傳」.
- The app (`UploadQueue.adoptInbox`, at launch and every time it becomes active) moves each file to `Documents/Imports/<uuid>/`, queues it with the sidecar's title, folder and language, and only then deletes the inbox entry. A missing or unreadable sidecar still queues the file under its own name. A file already moved by an earlier run isn't queued twice.
- The app writes `folders.json` (the folder tree, whenever the library loads) and the default language (App Group defaults, whenever settings load) for the extension's pickers. Before the first load the extension shows only the title and language.

**Signing**: both bundle IDs need the App Groups capability with `group.ai.3mi.tally` (the entitlements come from `project.yml`). For TestFlight or App Store, create distribution profiles for both `ai.3mi.tally` and `ai.3mi.tally.share`; `-allowProvisioningUpdates` does this when the group is registered for both IDs. The app and the extension share `CURRENT_PROJECT_VERSION` / `MARKETING_VERSION` (set once in `project.yml`), and these must match.

## Login (Cloudflare Access)

- The app first calls `GET /api/templates`. If Access answers with 401/403 or a redirect to `*.cloudflareaccess.com`, it opens the backend in a web view, and you sign in with the usual Access flow (team `3mi`).
- When the web view is back on the backend's host and has a `CF_Authorization` cookie, the app takes that JWT and stores it in the Keychain (AfterFirstUnlock, so uploads keep working while the phone is locked).
- API calls send the JWT in the `cf-access-token` header, and never as a cookie. The player sends it as a `CF_Authorization` cookie on the media request.
- When the token expires, the next 401/403 shows the login screen again, and the upload queue pauses until you sign in.
- Settings → 連線方式 → 切換連線方式 logs you out and clears the web view's cookies. Items still in the upload queue start over on the new backend, in 未分類.

## Login (Kiroku Cloud)

- The welcome screen offers **使用 Kiroku Cloud** or **連線到自己的伺服器** (the self-hosted URL / Access path, unchanged),
  plus 「兩者差別」 (https://kiroku.3mi.ai/?about#compare). 使用 Kiroku Cloud reads `GET /api/config` from https://kiroku.3mi.ai
  (DEBUG override: launch argument `-cloudURL http://127.0.0.1:8800`) and configures Clerk with the returned publishable key;
  with an existing session it goes straight in, otherwise 註冊 / 登入 open Clerk's `AuthView` in `.signUp` / `.signIn`
  (email code; Apple / Google only if enabled on the Clerk instance). An expired session shows `.signIn`.
- Every request sends `Authorization: Bearer <session token>`, fetched per request (`Clerk.shared.auth.getToken()`; the SDK
  caches it and refreshes it before its 60 s expiry), so the upload queue keeps working. A 401 shows the sign-in again.
- Playback goes through `MediaLoader` (an `AVAssetResourceLoaderDelegate`): each range request gets a fresh token, since
  AVPlayer would otherwise keep reusing one that expires mid-playback.
- Settings → 登出 / 切換連線方式 calls `Clerk.shared.auth.signOut()` and clears the stored cloud mode.
- `maestro/cloud/13-cloud-login.yaml` signs in a Clerk test user (`…+clerk_test@example.com`, code 424242); it is not part of
  the default suite since it needs a backend in clerk mode: `maestro test ios/maestro/cloud -e CLOUD=http://127.0.0.1:8800`.

## TestFlight

You need to provide:

1. A **paid Apple Developer Program team**. Put its team ID in `DEVELOPMENT_TEAM` in `project.yml`; the current value is a personal team, which can't upload to App Store Connect.
2. An **App Store Connect app record** with bundle ID `ai.3mi.tally`: register the ID under Certificates, Identifiers & Profiles, then go to App Store Connect → Apps → + → New App.
3. A way to authenticate the upload: either sign in to that team in Xcode → Settings → Accounts, or use an **App Store Connect API key** (issuer ID, key ID and `.p8` file, with the App Manager role).

Steps:

```sh
cd ios && /opt/homebrew/bin/xcodegen
# raise CURRENT_PROJECT_VERSION in project.yml for every upload
xcodebuild -scheme Tally -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Tally.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Tally.xcarchive -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates \
  [-authenticationKeyPath AuthKey_XXXX.p8 -authenticationKeyID XXXX -authenticationKeyIssuerID <issuer>]
```

`ExportOptions.plist` is a small plist with `method` = `app-store-connect`, `destination` = `upload` and `teamID` = your team ID. You can also use Xcode → Product → Archive → Distribute App → TestFlight. After the build finishes processing, add testers in App Store Connect → TestFlight. The app declares no non-exempt encryption (`ITSAppUsesNonExemptEncryption = NO`). Keep `.p8` keys and `build/` out of git.
