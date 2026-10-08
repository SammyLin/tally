# Tally for iOS

SwiftUI app (iOS 17+, no dependencies) for the Tally backend. Features (same API as the web front end):

- **Record**: keeps recording in the background and with the screen locked. You choose a title, folder and transcription language when you save.
- **Upload queue**: multipart uploads in 50 MiB parts, retried until they succeed. Queued items can be deleted (asks first). You can also import audio/video files with a chosen language.
- **Library**: 最近 / 全部 / 未分類 / 垃圾桶 and folders (create, subfolder, rename, move, delete), search, and a runner status header (online, queue size, remove offline runners).
- **Recording detail**: play and seek (up to 1.75×), speaker bands and legend, rename or merge speakers, confirm or reject a suggested speaker, edit a transcript line (asks before discarding edits), rename, move, retranscribe with a language, trash / restore / purge.
- **Summary**: Markdown rendering, delete. **Copy as prompt** uses the same format as the web's `buildPrompt`, for a whole recording or a selected range.
- **問問看**: ask questions across recordings, answers cite recordings and jump to that time. Retry or delete questions.
- **Settings**: AI text, default language, vocabulary (with suggestions and a 50-character limit; a rejected word keeps the sheet open), 我是誰, rename / merge / delete people, and change backend. Unsaved changes are guarded.
- **`tally://` links**: see Links below.

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

Unit tests (Swift Testing, `TallyTests/`: prompt format, upload parts and backoff, Access login, library, knowledge, parity):

```sh
cd ios && /opt/homebrew/bin/xcodegen
xcodebuild test -scheme Tally -destination 'platform=iOS Simulator,name=iPhone 17'
```

On first launch the app asks for the backend URL (default `https://records.3mi.ai`). For a local Worker, use `http://127.0.0.1:<port>`. Plain http is allowed only for local and LAN addresses.

### Maestro UI tests

`maestro test ios/maestro -e BACKEND=http://127.0.0.1:<port>` runs all 12 flows in `ios/maestro` against the booted simulator. They need a local Worker without Access, a freshly seeded database (`ios/maestro/seed-all.sh`) and a Debug build installed. Flows 07–12 change their data, so each full run needs a fresh database. See [maestro/README.md](maestro/README.md) for setup steps and the `-e BACKEND=… -e SHOTS=…` options.

## Links

`tally://` opens the app at the same places as the web's hash routes: `tally://recent|all|unfiled|trash|folder/<id>`, optionally
followed by `/rec/<id>[/summary]` (or just `tally://rec/<id>[/summary][?ms=<ms>]`), and `tally://ask[/<id>]`. Detail ⋯ →
「複製連結」 copies one. Links wait while a recording or the settings sheet is open.

## Login (Cloudflare Access)

- The app first calls `GET /api/templates`. If Access answers with 401/403 or a redirect to `*.cloudflareaccess.com`, it opens the backend in a web view, and you sign in with the usual Access flow (team `3mi`).
- When the web view is back on the backend's host and has a `CF_Authorization` cookie, the app takes that JWT and stores it in the Keychain (AfterFirstUnlock, so uploads keep working while the phone is locked).
- API calls send the JWT in the `cf-access-token` header, and never as a cookie. The player sends it as a `CF_Authorization` cookie on the media request.
- When the token expires, the next 401/403 shows the login screen again, and the upload queue pauses until you sign in.
- Settings → 變更後端 logs you out and clears the web view's cookies. Items still in the upload queue start over on the new backend, in 未分類.

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
