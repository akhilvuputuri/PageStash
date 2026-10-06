# Offline Reader

A private iPhone reading library that accepts articles and agent-prepared briefs, downloads text and images in the background, and opens local content without internet.

Native SwiftUI app · TypeScript backend · PostgreSQL · private object storage · authenticated HTTP/MCP ingestion.

## Current status

Implemented: sign-in, library, URL submission, asynchronous article extraction and supported images, Markdown briefs, local reader, persistent download queue, background refresh registration, integrity verification, reading position, search, collections, archive/delete, download removal, credential creation/revocation, OAuth and the three MCP tools.

The native app compiles without signing. Automated tests cover backend authorization, extraction fixtures, OAuth, MCP, durable jobs, local persistence, interrupted updates, and offline edit races. **Physical-device background execution, TestFlight, live Supabase/Render, and ChatGPT/Claude connections are not yet verified.** See [validation](docs/VALIDATION.md).

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

## Deployment and integration

- [Supabase and Render setup](docs/DEPLOYMENT.md)
- [HTTP, Telegram assistant, ChatGPT and Claude](docs/INTEGRATIONS.md)
- [Architecture and tradeoffs](docs/ARCHITECTURE.md)
- [Validation and device acceptance checklist](docs/VALIDATION.md)

## Background behavior

The app requests another refresh opportunity after 30 minutes. **That is an earliest opportunity, not an exact schedule.** iOS controls execution. Background refresh queries the library and hands downloads to native background `URLSession`; content is verified before becoming readable. Foreground and manual refresh use the same pipeline.

Unread, unarchived items download automatically, Wi-Fi by default, within a configurable device storage limit. Manually removing a download pauses automatic downloading for that item until you request it again. Downloads retry on subsequent refreshes; a partial attempt never destroys an existing readable copy. Missing source images are clearly labelled.

Do not swipe the app away while evaluating automatic refresh. Test Low Power Mode and Background App Refresh settings on your actual phone. Paid developer membership makes distribution easier; it does not change iOS scheduling.

## Scope

This is a personal beta with one allowed production email, designed with account ownership throughout. No LLM runs on the backend. There are no public feeds, PDF/EPUB imports, paywall bypassing, or built-in AI. The initial Markdown renderer supports headings, paragraphs, bold, fenced code, and links; advanced Markdown formatting and embedded images are deliberately deferred. The app does not promise a freshness deadline.
