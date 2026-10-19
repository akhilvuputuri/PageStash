# Supabase + Northflank Free deployment

## 1. Supabase

1. Create a **Personal / Free** organization named `Offline Reader`, then a project named `offline-reader` in Singapore (or a nearby compatible region). Enter and store the database password yourself. Creating a new credential is a user handoff step.
2. Disable public signups in Authentication. Create/invite your own application user and confirm its email. This is distinct from your Supabase dashboard account.
3. Create a **private** Storage bucket named `articles`. Do not enable public access or add anonymous read policies. The backend accesses files using its server credential; the phone gets revocable per-file download capabilities.
4. Gather the project URL, public anonymous/publishable key, server service-role/secret key, and PostgreSQL connection URI. Keep all secrets in Northflank runtime environment settings, never Git or chat. Use the connection mode recommended by Supabase for an external long-running service (session pooler when direct IPv6 is unavailable), with SSL enabled.
5. At first startup the backend creates its tables and enables RLS without public policies. Direct app/MCP access to Supabase's data API is not part of the design. Authorization is enforced by the backend on every API operation.

## 2. Northflank Free

1. Sign in to Northflank and create a **free/Sandbox** project named `offline-reader`. If free provisioning requires card verification, complete that yourself and check that the resource summary stays at $0. Do not upgrade to paid compute.
2. Connect GitHub with access limited to `akhilvuputuri/PageStash` (renamed from `offline-reader` on 15 October 2026). This is a separate grant from the earlier Render installation.
3. Create one **combined build and deployment service** from `main`, using Dockerfile `backend/Dockerfile` and build context `backend`. Do not add a database or a separate worker: PostgreSQL remains on Supabase and the import worker runs inside this same service.
4. Select an eligible free compute size. The initial target is at least 512 MB RAM and one replica. Prefer a nearby region when the free tier permits it. Confirm the service does not sleep and there is no paid resource in the project summary.
5. Expose HTTP container port **8787** using Northflank's generated HTTPS endpoint. Configure an HTTP readiness check on `/health` at that port, with enough initial delay for first-run migrations. Use manual deployments during the personal beta.
6. Set the runtime environment values from `backend/.env.example`: `NODE_ENV=production`, `HOST=0.0.0.0`, `PORT=8787`, `DEV_AUTH=false`, `PUBLIC_URL` to the **exact generated HTTPS origin**, `DATABASE_URL`, `OWNER_EMAIL`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_KEY`, `STORAGE_BUCKET=articles`. When using Supabase's URI template containing `[YOUR-PASSWORD]`, enter the existing password separately as `DATABASE_PASSWORD`; the server safely percent-encodes it. Keep `sslmode=verify-full` on the URI. Secrets belong at runtime, not in Docker build arguments. If the public URL is only available after creation, update it and redeploy before testing ingestion.
7. Deploy. Verify `GET /health`, private storage, an asynchronous brief, an article with images, and revoked-agent rejection. Record live results in `VALIDATION.md`.

Schema changes are additive and run at startup. Reader 0.3.x adds `items.site_name`; after deploying it, newly prepared articles carry their publisher's name, and older clients ignore the field. A later release adds the `connection_grants` table and the opt-in `list_saved_articles` tool. No existing connection gains access until the owner turns on **Share saved-article titles** in the new app build, and older app builds simply do not show the switch.

The production service does not store articles on the container's ephemeral disk. Restarting or redeploying must retain jobs, articles, and images in PostgreSQL/Supabase Storage. No persistent volume is needed for this server.

The container adds Supabase's public database CA to Node's trusted roots using `NODE_EXTRA_CA_CERTS`, while keeping `sslmode=verify-full`. The certificate is downloaded from the dashboard's Database Settings link (`https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt`). Refresh this public certificate if Supabase rotates its CA. For local production connections, set `NODE_EXTRA_CA_CERTS` to the absolute path of `backend/supabase-ca.crt` before starting Node.

The service processes up to three imports per worker cycle, with one active import per process. Saves wake the worker immediately. Empty queues are checked once per minute and expiry cleanup runs hourly. Queue leases expire after 10 minutes and allow crash recovery. Fetches are bounded; deploy interruption can leave an unreferenced uploaded file. Before expanding the beta, add a scheduled orphan-object audit with a retention window, and verify PostgreSQL upgrades using a backed-up project.

The repository retains `render.yaml` as an optional paid-hosting alternative, but Northflank Free is the selected target. No paid alternative should be provisioned without an explicit hosting decision.

## 3. iPhone signing and TestFlight

The personal developer team `U44PG44XMJ` is configured in the project and generator. The explicit App ID `com.akhilvuputuri.offlinereader` is registered under that team, and a valid Apple Development signing identity is available on the Mac. The personal iPhone is provisioned. Reader 0.2.0 (build 2) with its embedded Share Extension installed and launched on 9 October 2026. The owner previously confirmed production sign-in and article/image offline reading; the owner confirmed the new-release Sepia and browser-share flow. An in-place diagnostic update to 0.2.0 build 4 installed and launched on 13 October 2026. A controlled background-only sync/download test passed against the live server; naturally scheduled background execution remains pending. See [investigation evidence](VALIDATION.md#background-refresh-investigation-13-october-2026).

With Xcode 26.3 and this iOS 27 device, device-specific asset thinning failed. The successful installation used a generic signed Release build (`-configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates`) followed by `xcrun devicectl device install app --device <connected-device> <Release-iphoneos/OfflineReader.app>`. This preserves signing and the full asset set.

1. Open `ios/OfflineReader.xcodeproj` in Xcode.
2. In Signing & Capabilities, select your enrolled Apple development team. Confirm the bundle ID `com.akhilvuputuri.offlinereader` is available; update it if needed and keep the refresh identifier in Info.plist/AppDelegate consistent if changing identifiers.
3. Connect and trust your iPhone; enable Developer Mode when prompted. Select it as the run destination and build.
4. Configure the deployed HTTPS backend URL and your application user's email/password in the app.
5. **One-time App Store Connect setup (the owner, or an agent in the owner's signed-in browser at their request; agreements and compliance answers stay the owner's).** Create the App Store Connect app record for bundle ID `com.akhilvuputuri.offlinereader` under the personal seller account, accept any pending agreements, and answer the encryption/export and privacy questions yourself; do not assume these declarations from the repository. Add only yourself as an internal tester, and install TestFlight on the iPhone (turn on automatic updates there).
6. **Each release (internal TestFlight).** From the exact merged release commit, with a new build number in `scripts/generate-project.py`, run `scripts/upload-testflight.sh`. It archives a Release build and uploads it with `ios/ExportOptions-TestFlight.plist` (`app-store-connect`, `testFlightInternalTestingOnly`), signing and authenticating through the Apple account signed in to Xcode; no credentials are stored in the repository or passed on the command line. The script refuses to run unless HEAD is `origin/main` with a clean tree and a project that matches the generator. The app's Info.plist declares `ITSAppUsesNonExemptEncryption = NO`, the owner's export compliance answer (19 October 2026): PageStash uses only encryption built into iOS (HTTPS, the Keychain and CryptoKit hashing), with no proprietary or third-party cryptography. Builds therefore skip the Missing Compliance step. If the app ever adds other cryptography, the owner must revisit that answer; an agent never changes it. The build then reaches the owner's iPhone through TestFlight. Internal TestFlight builds expire after 90 days, so each release renews them. Direct `devicectl` installs (above) remain available for diagnostics.

## Browser Share Extension signing

The app and embedded `ReaderShare` target use `group.com.akhilvuputuri.offlinereader`. Both signed generic Release products have matching App Group entitlements and provisioning profiles verified locally. Automatic provisioning registered/configured the required group and extension on the existing team; Reader 0.2.0 with this extension installed and launched on the personal iPhone; no TestFlight/App Store distribution was performed. The main/extension bundle IDs are based on `READER_BUNDLE_IDENTIFIER`, so an isolated CI preview uses its own identifiers/group instead of sharing a real app container.

The containing app must be opened once after update to migrate its existing private Keychain session into the protected shared Keychain item. Sign in in the main app if necessary; the extension does not request or copy passwords. Check Safari and Chrome's real iPhone share sheet during combined-release acceptance, including an offline share, foreground/background delivery, logout during submission and explicit Retry after reauthentication. Compiling or signing an extension alone does not prove host-browser delivery.

## Operations

- Health endpoint tests database access but does not establish worker throughput or extraction success.
- Logs intentionally omit URLs, article bodies, passwords, tokens, and provider error responses. Disable proxy request-path logging for `/v1/downloads/*` and OAuth query strings, which can contain capabilities/codes. Audit the host's own access logging before adding users.
- Set spending alerts and quotas in both providers. Initial API limits cap the queue at 50 and the active library at 1,000 items, with bounded image count/bytes per article.
- Back up PostgreSQL and the private storage bucket; a database backup alone does not include images. Verify restore to a separate project before relying on it.
- Account deletion removes referenced stored objects, local records and Supabase Auth user. Provider backup retention is governed by the provider; maintain an explicit retention policy before public release.
- Revoke assistant connections in app Settings. A revoked connection cannot save/check submissions; app logout also invalidates that app session when connectivity is available.
- Local logout always destroys the local session/content immediately. If offline, server-side revocation cannot complete; the abandoned credential expires after 30 days and remains only as a hash on the server.
