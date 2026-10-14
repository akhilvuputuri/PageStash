# PageStash

PageStash (formerly Offline Reader; bundle identifiers and `offlinereader://` links keep the original name; the repository was renamed `akhilvuputuri/PageStash` on 15 October 2026).

A private iPhone reading library that accepts articles and agent-prepared briefs, downloads text and images in the background, and opens local content without internet.

Native SwiftUI app · TypeScript backend · PostgreSQL · private object storage · authenticated HTTP/MCP ingestion.

## Current status

Implemented: sign-in, library, URL submission, asynchronous article extraction and supported images, Markdown briefs, local reader, persistent download queue, background refresh registration, integrity verification, reading position, search, collections, archive/delete, download removal, credential creation/revocation, OAuth and the four MCP tools (saved-article listing only with the owner's per-connection opt-in).

The backend is deployed on Northflank Free with Supabase PostgreSQL; live health, anonymous-access rejection, and MCP discovery pass. The native app compiles for both a simulator and an unsigned iPhone build. Simulator checks passed for sign-in, article text/images, an MCP-created brief, cached reading after restarting with the local server stopped, reading position, search, offline edits and download removal/retry. Automated tests cover backend authorization, extraction fixtures, OAuth, MCP, durable jobs, local persistence, interrupted updates, and offline edit races. The owner also confirmed production sign-in and reading article text/images on the physical iPhone after restarting in Airplane Mode with Wi-Fi off. **Naturally scheduled physical-device background execution, TestFlight, and ChatGPT/Claude connections are not yet verified.** See [validation](docs/VALIDATION.md).

## Local development

Prerequisites: Node 22+, Xcode with the iOS SDK, and Python 3 only if regenerating the project. Docker is optional: local development and tests use embedded PostgreSQL (PGlite), while production uses PostgreSQL through `pg`.

```sh
cd backend
npm ci
cp .env.example .env
# Choose a local-only password in .env.
npm run build
node --env-file=.env dist/main.js
```

Development authentication runs only on loopback and refuses production mode. It is a standalone local test account, not your Supabase dashboard login. State persists in `backend/.local`, which Git ignores. Open `ios/OfflineReader.xcodeproj`, select the `OfflineReader` scheme, choose your Apple development team, and run.

For a simulator, use `http://127.0.0.1:8787` and the development email/password configured in `.env`. For a physical iPhone, use the deployed HTTPS backend; the development server intentionally does not expose password authentication over your LAN. Release builds require HTTPS.

```sh
cd backend
npm run check
npm test
npm run build
cd ../ios/ReaderCore
swift test
```

Unsigned device compilation from the repository root:

```sh
xcodebuild -project ios/OfflineReader.xcodeproj -scheme OfflineReader \
  -destination 'generic/platform=iOS' -derivedDataPath work/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Unsigned compilation is a build check. To run the simulator and exercise Keychain session storage, build normally in Xcode, or use ad-hoc simulator signing:

```sh
xcodebuild -project ios/OfflineReader.xcodeproj -scheme OfflineReader \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/SimulatorDerivedData ARCHS="$(uname -m)" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

## Deployment and integration

- [Supabase and Northflank Free setup](docs/DEPLOYMENT.md)
- [HTTP, Telegram assistant, ChatGPT and Claude](docs/INTEGRATIONS.md)
- [Framework-neutral agent adapter handoff](docs/AGENT_ADAPTER.md)
- [Architecture and tradeoffs](docs/ARCHITECTURE.md)
- [Validation and device acceptance checklist](docs/VALIDATION.md)

After creating your confirmed Supabase application user, run the backend acceptance check from the repository root:

```sh
node scripts/verify-backend.mjs
```

It prompts for your app password without echoing or storing it, saves a demonstration brief through MCP and a public article, verifies file hashes and duplicate retries, then checks agent restrictions and revocation. It retains the two demonstration items for phone testing and revokes its temporary credential/session. It never needs database or Supabase service keys. Optional `READER_URL`, `READER_EMAIL`, and `READER_ARTICLE_URL` environment values select another backend, account, or public source. This command checks the server; the phone's offline behavior still requires device acceptance.

Appearance is configurable in Settings → Appearance: Light (the default), Sepia, Dark, or System. Light uses white pages; Sepia uses warm off-white pages with brown text. Both apply to existing cached articles and briefs. Sepia ships in the installed 0.2.0 personal release.

## Import failures

Only prepared readable articles enter Library. Pending and failed submissions appear under Imports with their status and a Retry action when an original article URL is available. Missing optional images keep readable text, with warnings and placeholders. Existing records are retained; this does not retrospectively audit or delete older captures.

The HTTP/MCP status value `bookmark` is retained for compatibility but now describes a failed submission outside the normal article list. A new intentional save of the same owned failed URL retries its retained submission; repeating a known request key never silently starts another attempt. The server adds a private retry-receipt registry on startup. These changes ship in 0.2.0, with backend revision `89d28a5` deployed on Northflank Free.

## Browser sharing

The embedded PageStash share destination accepts a webpage URL from Safari/Chrome. It displays the PageStash destination and queues the selected link before submitting. Multiple shared links require an explicit choice. Offline shares remain queued on this device and are sent when the app next has connectivity and a valid sign-in; background scheduling is controlled by iOS.

Open the updated app once before first use. Logout clears queued shares. After re-signing in, old queued links require explicit Retry with the same account/destination; installed readable content is retained. Submitted/prepared status is separate from verified offline availability. Reader 0.2.0 is installed and launched on the personal iPhone; the owner confirmed Sepia and browser share submission work. Naturally scheduled background delivery remains unverified.

## Background behavior

The server worker wakes immediately after a save, polls once per minute when idle for crash/retry recovery, and removes expired credentials/download grants hourly. One import runs at a time; small batches yield between cycles. This avoids constant database housekeeping for the single-user beta.

The app requests another refresh opportunity after 30 minutes. **That is an earliest opportunity, not an exact schedule.** iOS controls execution. Background refresh queries the library and hands downloads to native background `URLSession`; content is verified before becoming readable. Foreground and manual refresh use the same pipeline.

Unread, unarchived items download automatically, Wi-Fi by default, within a configurable device storage limit. Manually removing a download pauses automatic downloading for that item until you request it again. Downloads retry on subsequent refreshes; a partial attempt never destroys an existing readable copy. Missing source images are clearly labelled.

Going Home or locking the phone leaves Reader eligible for refresh. Swiping it away generally blocks background relaunch and cancels native transfers until Reader is opened again. Do not swipe the app away while evaluating automatic refresh. Test Low Power Mode and Background App Refresh settings on your actual phone. Paid developer membership makes distribution easier; it does not change iOS scheduling.

Build 4 records bounded local scheduling, wake, sync and verified-download diagnostics for troubleshooting. It retains no article text, URLs, item/account IDs, credentials or raw error messages. A controlled physical-device test passed; naturally scheduled delivery is still unverified. See [device investigation](docs/VALIDATION.md#background-refresh-investigation-13-october-2026).

## Scope

This is a personal beta with one allowed production email, designed with account ownership throughout. No LLM runs on the backend. There are no public feeds, PDF/EPUB imports, paywall bypassing, or built-in AI. The initial Markdown renderer supports headings, paragraphs, bold, fenced code, and links; advanced Markdown formatting and embedded images are deliberately deferred. The app does not promise a freshness deadline.

## Library UI (issue 1)

The Library UI replaces Inbox/Offline/Archived tabs with one Library and a secondary Archive destination. Done reading marks read and archives with Undo, while preserving installed files and the device reading position. It trims reader actions and moves connection/account management into secondary settings screens. See [implementation validation](docs/VALIDATION.md#issue-1-library-and-completion-8-october-2026); this UI ships in the installed 0.2.0 personal release.
