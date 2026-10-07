# Validation record

Build date: 6 October 2026. This record separates completed checks from required live/device acceptance. A passing local test is not evidence of iOS scheduling or host compatibility.

## Completed locally

- TypeScript type-check and backend build.
- Native iOS unsigned Debug and Release compilation against Xcode 26.3 / iOS 26.2 SDK, including the bundled privacy manifest and Release HTTPS enforcement.
- Backend PostgreSQL tests: private and mapped IP blocking, sanitization, article/image extraction fixtures, brief import, idempotency, account isolation, restricted credentials, OAuth PKCE/consent/code replay/refresh/revocation, MCP discovery/tool execution/auth challenge, and expired worker lease recovery.
- SQLite tests on macOS: text/image persistence across storage reopen; corrupt downloads rejected; old content retained during incomplete replacement; pending edit acknowledgement race; tombstones reject late downloads; download removal retains bookmarks and pauses auto-download; unsafe filenames rejected.
- Dependency audit after upgrading the image processor: no known vulnerabilities reported at that check.
- Live public extraction smoke check: Wikipedia's “Airplane mode” article captured six images with no missing-image warnings. This verifies real network extraction, not iPhone offline behavior.
- 10 backend tests and 6 Swift storage tests passed. The backend tests include account deletion of referenced and orphaned files.
- Complete live local HTTP smoke passed: sign-in → restricted assistant credential → asynchronous brief import → hash-verified download → reading/collection edit sync. No real account credentials were used.
- GitHub CI passed independently on Linux (backend tests/build/audit) and macOS (Swift storage tests and unsigned iPhone compilation): https://github.com/akhilvuputuri/offline-reader/actions/runs/37459427884

## Provisioning progress

- Private repository created and initial implementation pushed to `akhilvuputuri/offline-reader`.
- User created a healthy Supabase Free project in Tokyo. The original Singapore suggestion is optional; the existing Tokyo project can serve this personal beta.
- Empty private `articles` bucket created with no public access policies.
- User signed into Render. Its GitHub connection requires explicit approval for repository access before deployment can proceed.
- No Render paid service has been provisioned. No Supabase secrets have been transferred to Render or committed to Git.
- No iPhone is connected and no local code-signing identity is present. A simulator runtime is also absent; available disk space is insufficient to casually install a large runtime. The next device acceptance should use the physical iPhone.

### Update: 7 October 2026

- User selected **Northflank Free** for the server, keeping Supabase. The paid Render service draft remains unsubmitted.
- Server worker now wakes on new saves/retries, checks idle queues every minute, and performs expiry cleanup hourly. Added tests for immediate wake-up, a save racing with an empty claim, non-overlapping execution, outage retry, and shutdown.
- Local backend type-check/build and all 13 backend tests passed after the worker change. Native storage code was unchanged.
- Northflank account sign-in, free project/resource limits, repository authorization, runtime secret setup and live deployment remain pending verification.

### Northflank configuration progress

- Free team and `offline-reader` project created in US Central. Free region choices were US Central and London; Asian regions require a paid plan.
- User completed Northflank's required card verification. The project remains on Developer Sandbox.
- GitHub installation is verified as **Only select repositories**, with exactly `akhilvuputuri/offline-reader` selected.
- `reader-api` combined-service draft uses `/backend/Dockerfile`, `/backend` context, one `nf-compute-20` replica (0.2 shared vCPU / 512 MB), manual builds, public HTTP port 8787 and a `/health` readiness probe.
- Approved API keys are populated in the draft's runtime environment, with the TLS session-pooler URI template. No secret values were written to Git or deliverable files.
- Added a separate `DATABASE_PASSWORD` runtime option to safely encode reserved characters into Supabase's URI template. Type-check, build and all 16 backend tests passed.
- User entered the database password and created the free service. The first container build passed but startup failed because Node did not trust Supabase's database CA. Added the official public CA via `NODE_EXTRA_CA_CERTS`, preserving `sslmode=verify-full`; independently verified the pooler's certificate and hostname without credentials.

### Live deployment: 7 October 2026

- Northflank build `eloquent-spirit-8458` deployed commit `f635e40`. One `nf-compute-20` instance is running on the Free team with its HTTP readiness probe passing (200) and zero restarts for the corrected deployment.
- HTTPS origin: `https://p01--reader-api--2sn8tjhm47hb.code.run`.
- `GET /health` returned 200 and `{"ok":true}`, verifying the production PostgreSQL connection and completed startup migrations.
- Anonymous `GET /v1/library` returned 401. OAuth protected-resource discovery returned 200 with the deployed origin; MCP initialize returned 200 and the expected server capabilities.
- GitHub CI passed for the deployed commit: https://github.com/akhilvuputuri/offline-reader/actions/runs/37563016494.
- Personal Supabase application-user creation remains a human handoff. Authenticated ingestion, private asset upload/download and restart recovery on this host remain unverified.

### Additional acceptance work: 7 October 2026

- The end-to-end verification script caught bodyless DELETE requests incorrectly carrying a JSON content type in the iPhone client. Fixed the client request headers; malformed client requests now retain their proper 4xx status instead of appearing as server failures.
- Added a regression covering HTTP credential revocation, session logout, expired download capabilities and retained library items. All 17 backend tests pass.
- `scripts/verify-backend.mjs` passed against an isolated local backend: an MCP-created brief, a public article with six images, eight size/hash-verified files, idempotent retries, agent library rejection and revoked-agent rejection. This is real extraction and local storage, not a Supabase production ingestion test.
- iOS Debug simulator compilation passed after aligning the app's active architecture with its Swift package. An iOS 26.3 simulator runtime is now installed; no new runtime download was needed.
- Final unsigned Release device compilation also passed. Installed and launched the Debug build on the existing iPhone 17 Pro simulator; launch returned a running process, but visual rendering/sign-in remain unverified while the Mac is locked.
- Cellular changes now cancel/requeue requests under the new policy without discarding verified files. Download enqueue operations are serialized, late failures from an old login are ignored, and article version changes restore the saved reading position.
- The deployed origin is prefilled on login. Settings displays its MCP endpoint even without existing connections, with account controls in their own section.
- UI interaction remains blocked while the Mac is locked. No physical iPhone is connected and no local signing identity is available at this check.
- Redeployed commit `4cc6e36` to Northflank Free. The new instance is Running (1/1); live health returned 200, anonymous library access 401, and an empty JSON DELETE request 400. Independent CI passed: https://github.com/akhilvuputuri/offline-reader/actions/runs/37565183768.
- Added simulator compilation to CI; the exact command passes locally without requiring a simulator runtime on the CI runner.

### Offline sync verification: 7 October 2026

- Fixed a manual-download race: full-manifest requests now follow an active incremental sync rather than incorrectly treating it as sufficient. Concurrent retries share that follow-up refresh instead of duplicating it.
- Sync cancellation is isolated by run identity, so a cancelled old login cannot clear a newer login's sync. Added generation/cancellation checks after edit uploads and download enqueueing before acknowledging edits or updating the last-sync state.
- All 14 Swift tests pass. New cases cover coordinated full/incremental syncs, cancellation across logins, recovery after failure, same-size hash corruption, stale-version downloads, sync-page transaction rollback, and offline edits/download pauses surviving a restart.
- Unsigned Release iPhone and Debug simulator builds pass after this change. Backend code and deployment are unchanged.

### Interactive simulator acceptance: 7 October 2026

- The Mac became available for UI interaction. Used an isolated loopback backend and a synthetic development account, with no Supabase service keys or real app password.
- The unsigned simulator initially failed to save its session in Keychain. Rebuilt with normal ad-hoc simulator signing; login and session persistence then passed. Keychain storage was preserved rather than bypassed.
- Submitted Wikipedia's Airplane mode URL through the app. The backend captured six images; the app reached Available offline and rendered text/images. Larger text worked.
- Stopped the loopback backend and confirmed its health endpoint was unreachable. Restarted the app; the library, cached article, images and reading position remained usable. This is a simulator cache/restart check, not physical iPhone airplane-mode or naturally scheduled background execution.
- Body-text search matched handheld; a nonsense query returned no matches. Offline collection and archive edits survived another restart, then reached the local backend with the reading-position edit after reconnection/manual refresh.
- Saved an agent brief through authenticated MCP. It appeared as AGENT BRIEF in the app, rendered as AGENT-CREATED BRIEF with its source reference, and reached Available offline.
- Removing the article download retained the bookmark and displayed Not downloaded. Explicit Download now restored all assets and Available offline.
- Foreground refresh now restarts its shorter import-polling loop immediately when a save introduces pending imports. Updated Xcode-generated scheme metadata and documented simulator signing.
- Apple Account sign-in is now visible in Xcode. No physical iPhone or valid development signing identity was detected; Xcode's empty certificate panel currently shows disabled creation entries. Supabase application-user creation is still pending.
- Apple Developer portal confirms active individual membership and accepted developer agreements. Registered the explicit App ID `com.akhilvuputuri.offlinereader` under team `U44PG44XMJ`; configured that team in the Xcode project and its generator. No additional capabilities were enabled beyond Apple's default App ID settings.
- App Store Connect's apps page displays its navigation but fails to load its Apple-hosted preflight module. Its private app record has not yet been created. No build has been uploaded or submitted for review.
- A later Xcode refresh shows the Mac's Apple Development certificate. Signing-identity metadata checked outside the shell sandbox confirms one valid identity. No private keys were exported. A physical iPhone is still not connected, so device provisioning/installation remain pending.
- Independent CI passed for the simulator acceptance/polling/team configuration commit: https://github.com/akhilvuputuri/offline-reader/actions/runs/37619218742.

## Not yet tested

- Signed installation or TestFlight upload.
- Complete SwiftUI accessibility/layout coverage and physical-device rendering. Main simulator flows have passed interactive checks.
- An actual article with images reopening on the iPhone after a restart in airplane mode.
- Naturally scheduled background refresh over multiple days, low-power restrictions, reboot/force-quit behavior and background transfer relaunch callbacks.
- Live Supabase authentication/private storage; production PostgreSQL startup and health have passed, while ingestion tests still use embedded PostgreSQL.
- Northflank restart/crash recovery and provider access-log configuration. Render is an unprovisioned alternative.
- Real ChatGPT/Claude OAuth linking and token refresh.
- Existing Telegram assistant configuration and a real save request through that assistant.
- Backup restoration, large libraries, accessibility audit and provider account deletion failure recovery.

## Physical-device acceptance

1. Install a signed build and sign in to the deployed backend.
2. Save a public article with images. Wait for `Available offline`, not merely `Ready` on the server.
3. Close/relaunch the app in airplane mode. Read the complete text/images, search text, change reading position, archive/add a collection, and restart again.
4. Reconnect. Verify queued changes arrive once and do not regress on refresh.
5. Put the app in the background without swiping it away. Save a second article externally. Confirm a **naturally scheduled** run downloads it; record save/refresh/completion times. Repeat with Wi-Fi, cellular disabled, Low Power Mode and Background App Refresh disabled.
6. Interrupt an image transfer, restart the app, refresh and verify recovery. Test expired download capabilities and a changed content version.
   While transfers are pending, toggle cellular access on and off; confirm existing requests restart under the selected policy and verified files remain readable.
7. Remove a download and verify it stays removed during automatic sync. Explicit download must restore it.
8. Sign out while downloads are active; verify late callbacks cannot restore content. Sign in again and verify a fresh local library.
9. From each assistant host save an article and labelled brief, check status, retry identical submissions and revoke access. Verify library management fails using that agent credential.
10. In an isolated test account, verify deletion removes account data and referenced private files. Do not use your real library as disposable test data.

## Release gate

Do not describe the app as device-ready until signed installation, real offline reading, and natural background downloading have been observed. Do not describe ChatGPT or Claude as supported until their live checks pass. This is a personal beta; public release requires the operational/security work listed in `ARCHITECTURE.md`.
