# Agent setup

This repository depends on [a-stack](https://github.com/akhilvuputuri/a-stack) for shared agent skills, pinned to tag `ios-design--v0.1.0`.

| Skill | Use it for |
| --- | --- |
| `ios-design` | Any change to how the iOS app looks or feels: SwiftUI views, theming, typography, accessibility, icons, copy. Audits and implementations follow its workflow and verification matrix, and cite the HIG reference it links. |

## Claude Code

`.claude/settings.json` declares the a-stack marketplace at the pinned tag and enables `ios-design@a-stack`. After you trust this folder, Claude Code registers the marketplace and loads the skill; no separate install is needed. Check with `claude plugin list`, or invoke it as `/ios-design:ios-design`.

## Codex and other agents

This repository doesn't pin the skill for Codex. Install the same tagged version into Codex's user skills directory, replacing any older copy. Codex discovery of `~/.agents/skills` hasn't been verified for this skill yet.

```sh
tmp=$(mktemp -d)
git clone --depth 1 --branch ios-design--v0.1.0 https://github.com/akhilvuputuri/a-stack "$tmp"
mkdir -p ~/.agents/skills && rm -rf ~/.agents/skills/ios-design && cp -R "$tmp/skills/ios-design" ~/.agents/skills/
rm -rf "$tmp"
```

For agents without skill support, read `skills/ios-design/SKILL.md` from that tag and follow it, loading its references as directed.

## Updating the pin

a-stack tags each reviewed release `ios-design--v<version>`, and Claude Code fetches a new copy only when that version changes. To upgrade, change the tag in `.claude/settings.json` and in this file in one pull request. Never point the pin at a branch.
