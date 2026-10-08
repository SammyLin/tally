# Tally for iOS

SwiftUI app (iOS 17+, no dependencies) for the Tally backend: record (keeps going in the background and when the screen is locked), queue uploads (multipart, 50 MiB parts, retried until they succeed), browse and play recordings, rename speakers, read summaries, and "copy as prompt" (same format as the web's `buildPrompt`).

## Build and run

`Tally.xcodeproj` is generated from `project.yml` and is not committed:

```sh
cd ios
/opt/homebrew/bin/xcodegen
open Tally.xcodeproj                      # or build from the command line:
xcodebuild -scheme Tally -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Tally.app
```

Unit tests: `xcodebuild test -scheme Tally -destination 'platform=iOS Simulator,name=iPhone 17'`.

On first launch the app asks for the backend URL (default `https://records.3mi.ai`). For a local Worker, use `http://127.0.0.1:<port>`; plain http is allowed only for local and LAN addresses.

## Maestro UI tests

`maestro test ios/maestro` runs the flows in `ios/maestro` against the booted simulator. They need a local Worker on 127.0.0.1:8795 without Access, a seeded recording, and a Debug build installed. See [maestro/README.md](maestro/README.md) for the setup steps and the `-e BACKEND=… -e SHOTS=…` options.

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
