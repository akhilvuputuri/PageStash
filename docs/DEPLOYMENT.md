# Supabase + Northflank Free deployment

## 1. Supabase

1. Create a **Personal / Free** organization named `Offline Reader`, then a project named `offline-reader` in Singapore (or a nearby compatible region). Enter and store the database password yourself. Creating a new credential is a user handoff step.
2. Disable public signups in Authentication. Create/invite your own application user and confirm its email. This is distinct from your Supabase dashboard account.
3. Create a **private** Storage bucket named `articles`. Do not enable public access or add anonymous read policies. The backend accesses files using its server credential; the phone gets revocable per-file download capabilities.
4. Gather the project URL, public anonymous/publishable key, server service-role/secret key, and PostgreSQL connection URI. Keep all secrets in Northflank runtime environment settings, never Git or chat. Use the connection mode recommended by Supabase for an external long-running service (session pooler when direct IPv6 is unavailable), with SSL enabled.
5. At first startup the backend creates its tables and enables RLS without public policies. Direct app/MCP access to Supabase's data API is not part of the design. Authorization is enforced by the backend on every API operation.

## 2. Northflank Free

1. Sign in to Northflank and create a **free/Sandbox** project named `offline-reader`. If free provisioning requires card verification, complete that yourself and check that the resource summary stays at $0. Do not upgrade to paid compute.
2. Connect GitHub with access limited to `akhilvuputuri/offline-reader`. This is a separate grant from the earlier Render installation.
3. Create one **combined build and deployment service** from `main`, using Dockerfile `backend/Dockerfile` and build context `backend`. Do not add a database or a separate worker: PostgreSQL remains on Supabase and the import worker runs inside this same service.
4. Select an eligible free compute size. The initial target is at least 512 MB RAM and one replica. Prefer a nearby region when the free tier permits it. Confirm the service does not sleep and there is no paid resource in the project summary.
5. Expose HTTP container port **8787** using Northflank's generated HTTPS endpoint. Configure an HTTP readiness check on `/health` at that port, with enough initial delay for first-run migrations. Use manual deployments during the personal beta.
6. Set the runtime environment values from `backend/.env.example`: `NODE_ENV=production`, `HOST=0.0.0.0`, `PORT=8787`, `DEV_AUTH=false`, `PUBLIC_URL` to the **exact generated HTTPS origin**, `DATABASE_URL`, `OWNER_EMAIL`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_KEY`, `STORAGE_BUCKET=articles`. Secrets belong at runtime, not in Docker build arguments. If the public URL is only available after creation, update it and redeploy before testing ingestion.
7. Deploy. Verify `GET /health`, private storage, an asynchronous brief, an article with images, and revoked-agent rejection. Record live results in `VALIDATION.md`.

The production service does not store articles on the container's ephemeral disk. Restarting or redeploying must retain jobs, articles, and images in PostgreSQL/Supabase Storage. No persistent volume is needed for this server.

The service processes up to three imports per worker cycle, with one active import per process. Saves wake the worker immediately. Empty queues are checked once per minute and expiry cleanup runs hourly. Queue leases expire after 10 minutes and allow crash recovery. Fetches are bounded; deploy interruption can leave an unreferenced uploaded file. Before expanding the beta, add a scheduled orphan-object audit with a retention window, and verify PostgreSQL upgrades using a backed-up project.

The repository retains `render.yaml` as an optional paid-hosting alternative, but Northflank Free is the selected target. No paid alternative should be provisioned without an explicit hosting decision.

## 3. iPhone signing and TestFlight

1. Open `ios/OfflineReader.xcodeproj` in Xcode.
2. In Signing & Capabilities, select your enrolled Apple development team. Confirm the bundle ID `com.akhilvuputuri.offlinereader` is available; update it if needed and keep the refresh identifier in Info.plist/AppDelegate consistent if changing identifiers.
3. Connect and trust your iPhone; enable Developer Mode when prompted. Select it as the run destination and build.
4. Configure the deployed HTTPS backend URL and your application user's email/password in the app.
5. Create an App Store Connect app with that bundle ID and personal seller account. Archive a Release build and upload using Xcode Organizer. Review the privacy declarations and encryption/export questions yourself; do not assume these declarations from the repository.
6. Add only yourself as an internal TestFlight tester initially. Each beta build needs renewal within Apple's TestFlight lifetime. Increment `CURRENT_PROJECT_VERSION` for each upload.

## Operations

- Health endpoint tests database access but does not establish worker throughput or extraction success.
- Logs intentionally omit URLs, article bodies, passwords, tokens, and provider error responses. Disable proxy request-path logging for `/v1/downloads/*` and OAuth query strings, which can contain capabilities/codes. Audit the host's own access logging before adding users.
- Set spending alerts and quotas in both providers. Initial API limits cap the queue at 50 and the active library at 1,000 items, with bounded image count/bytes per article.
- Back up PostgreSQL and the private storage bucket; a database backup alone does not include images. Verify restore to a separate project before relying on it.
- Account deletion removes referenced stored objects, local records and Supabase Auth user. Provider backup retention is governed by the provider; maintain an explicit retention policy before public release.
- Revoke assistant connections in app Settings. A revoked connection cannot save/check submissions; app logout also invalidates that app session when connectivity is available.
- Local logout always destroys the local session/content immediately. If offline, server-side revocation cannot complete; the abandoned credential expires after 30 days and remains only as a hash on the server.
