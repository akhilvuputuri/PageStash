# PageStash development

## Workflow

This repository follows the [skills engineering workflow](https://github.com/akhilvuputuri/skills/blob/skills--v0.2.0/CORE.md), pinned to marketplace ref `skills--v0.2.0`. Claude Code loads it through the `skills@skills` plugin pinned in `.claude/settings.json`. Other agents should read the linked CORE.md at that tag before starting work. The bindings below supply this repository's specifics and win where they are more specific.

Non-negotiable even without the plugin:

- Fetch origin and read from `origin/main` before exploring or changing anything, and again whenever you cannot establish that the last fetch is still current. Never reset or clean a shared or dirty checkout. Work on a branch or worktree.
- Every change gets an independent reviewer that did not write it, with an explicit APPROVE or REQUEST CHANGES for the exact head SHA. Re-review after every fix.
- A task ends at verified delivery (exact deployed SHA or installed build, and evidence) or a named blocker.
- Label claims as reported, tested, measured, hypothesis or deferred. Never invent results. A supplied memory or context item is not proof the model used it.
- Commit as the human developer's git identity, with no agent author or `Co-Authored-By` trailer. If the identity is unset or shows an agent, stop and ask; never set one yourself. Keep secrets and private data out of the repository, PRs and logs.

### Workflow bindings

- **Read first:** [README.md](README.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), the "Not yet tested" and "Release gate" sections of [docs/VALIDATION.md](docs/VALIDATION.md), and the relevant source.
- **Checks:**
  - Backend: in `backend/`, run `npm ci`, `npm run check`, `npm test`, `npm run build` and `npm audit --omit=dev --audit-level=high`.
  - iOS: in `ios/ReaderCore`, run `swift test`. Then run the unsigned device and simulator `xcodebuild` builds from the README.
  - CI (`.github/workflows/checks.yml`) also runs the app icon check (`swift scripts/check-icon.swift` on every `ios/OfflineReader/Assets.xcassets/AppIcon.appiconset/AppIcon*.png`: light, dark and tinted), the native presentation tests and, on PRs, an isolated preview build. Run the icon check whenever the icon or `scripts/draw-icon.swift` changes.
  - Do not run routinely: none are paid. Live endpoint checks against production run only as part of a release. `scripts/verify-backend.mjs` is owner-only: by default it targets production with the owner's account, prompts interactively for that app password, and keeps demonstration items in the library. Run it only when the owner asks.
  - Visual checks use the debug-only `--preview-library` synthetic store under the preview bundle identifier, never a real library.
- **Reviewer:** the most capable model available (Opus 5.5 in Claude sessions). There is no bot review. UI changes are also checked against the `ios-design` skill.
- **Merge authority:** merge passing, independently approved PRs for changes the owner requested, with `gh pr merge N --merge --match-head-commit SHA`.
  - App releases need the owner's explicit authorization: the version and build bump, the `vX.Y.Z` tag and GitHub Release.
  - So do backend deploys and installs on the owner's iPhone.
  - The owner chose internal TestFlight as the release channel (19 October 2026): an authorized app release is uploaded with `scripts/upload-testflight.sh` from the exact merged release commit (docs/DEPLOYMENT.md). Xcode may create the distribution certificate and profiles that an authorized upload needs. Never submit for App Review, add external testers or publish on the App Store, and never change the team, signing style, bundle IDs, entitlements or capabilities, without a specific request.
- **Release:**
  - Backend: a manual Northflank Free build of the exact merged SHA to `reader-api` ([docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)). `/health` doesn't report a SHA, so the Northflank build record naming that commit is the evidence of what is deployed. Then verify Running with passing health probes, `/health` 200, anonymous `/v1/library` 401 and OAuth discovery 200.
  - Schema changes are additive and run at startup.
  - App: an internal TestFlight upload of the exact merged release commit with `scripts/upload-testflight.sh`, per DEPLOYMENT.md. Evidence is the App Store Connect build record (version, build, processed and available to internal testers) and the installed build on the owner's iPhone. Export compliance is the owner's answer, never an agent's: the owner declared `ITSAppUsesNonExemptEncryption = NO` (DEPLOYMENT.md), and any new cryptography goes back to the owner. A direct signed install with `devicectl` remains for diagnostics. Bump the version and build in `scripts/generate-project.py` (`MARKETING_VERSION, BUILD`), then regenerate `project.pbxproj` and the shared scheme with `python3 scripts/generate-project.py`; never edit only the pbxproj. Each build needs a new build number. Tags are immutable `vX.Y.Z` with a GitHub Release.
  - Never provision paid hosting.
- **Records:** [docs/VALIDATION.md](docs/VALIDATION.md) records every change, review, release and deploy, with dated sections, exact SHAs and the limits that remain. There is no separate journal, work index or handover. Release notes are the GitHub Releases. Respect its release gate: never call the app device-ready, or ChatGPT/Claude supported, before the listed live checks pass.
- **Diagnostics:** the Northflank service UI and the live endpoint checks above. There is no capability or doctor command. Production secrets live only in Northflank and Supabase; never in Git, chat or CI.
- **Exceptions:** none.

## Shared skills from akhilvuputuri/skills

The `skills@skills` plugin carries both groups:

| Skills | Use them for |
| --- | --- |
| `preflight`, `independent-review`, `ship`, `journal`, `incident`, `experiment`, `adopt` | The development workflow above |
| `ios-design` | Any change to how the iOS app looks or feels: SwiftUI views, theming, typography, accessibility, icons, copy. Audits and implementations follow its workflow and verification matrix, and cite the HIG reference it links |

**Claude Code:** `.claude/settings.json` declares the `skills` marketplace at the pinned tag and enables `skills@skills`. After you trust this folder, Claude Code registers the marketplace and loads it. Check with `claude plugin list`.

**Codex:** run these once:

```sh
codex plugin marketplace add akhilvuputuri/skills@skills--v0.2.0
codex plugin add skills@skills
```

`.codex/config.toml` keeps it enabled in this trusted project. The Codex plugin has no hooks, so the rules above are Codex's always-on workflow.

**Other agents:** run `npx skills add https://github.com/akhilvuputuri/skills/tree/skills--v0.2.0`. Without skill support, read `skills/ios-design/SKILL.md` at that tag and follow it.

Remove any older manually copied `~/.agents/skills/ios-design` before installing the plugin.

**Earlier installs.** Up to 0.1.x the marketplace shipped two plugins, `workflow@skills` and `ios-design@skills`. After pulling the new pin they show as disabled in `claude plugin list`. Remove them with `claude plugin uninstall workflow@skills --scope project` and `claude plugin uninstall ios-design@skills --scope project`, using the scope that `claude plugin list` shows. Then restart Claude Code in this folder. If `claude plugin list` still has no enabled `skills@skills` 0.2.0, run `claude plugin marketplace add akhilvuputuri/skills@skills--v0.2.0 --scope project` and `claude plugin install skills@skills --scope project`. These leave `.claude/settings.json` unchanged. Don't run `claude plugin marketplace remove skills`: it deletes the pin from `.claude/settings.json`. In Codex, `codex plugin remove workflow@skills`, `codex plugin remove ios-design@skills` and `codex plugin marketplace remove skills`, then run the Codex steps above. The marketplace was called `a-stack` before 0.1.2: if you registered it under that name, first remove it. In Claude Code, `claude plugin marketplace remove a-stack` also removes its plugins. In Codex, run `codex plugin remove workflow@a-stack`, `codex plugin remove ios-design@a-stack` and then `codex plugin marketplace remove a-stack`; removing only the marketplace leaves the old plugins enabled, so every skill loads twice.

**Updating the pin:** akhilvuputuri/skills tags reviewed releases `skills--v<version>`. Claude Code and Codex fetch a new copy only when the plugin's version changes. Change the ref in `.claude/settings.json` and this file in one PR, and never point it at a branch. Codex users run `codex plugin marketplace remove skills` and then `codex plugin marketplace add` with the new ref, because adding the same name from a different ref fails.
