# Tokei

macOS menu bar app that tracks your Claude Code usage: today's and this month's token cost per model (from local transcripts) and your remaining 5-hour / weekly quota (from Anthropic's usage endpoint).

The menu bar shows remaining session quota (e.g. `82%`); the popover shows quota bars with reset times, per-model cost for today and this month, and a Launch at Login toggle.

## Requirements

- macOS 14+
- Swift 6 toolchain (Command Line Tools are enough — no Xcode needed)
- Claude Code installed and signed in

## Install

```sh
./scripts/bundle.sh
cp -R dist/Tokei.app /Applications/
open /Applications/Tokei.app
```

## How it works

- **Usage/cost**: parses `~/.claude/projects/**/*.jsonl` transcripts locally. Streaming placeholder records are deduped by message id; rescans are incremental (per-file offsets), so refreshes are cheap. Pricing comes from LiteLLM's model price catalog, with a bundled snapshot as offline fallback.
- **Quota**: reads Claude Code's OAuth token from the macOS Keychain (`Claude Code-credentials`) and polls `api.anthropic.com/api/oauth/usage` every 5 minutes. Nothing else leaves your machine.
- **Live updates**: FSEvents watch on the projects directory — new Claude Code activity shows up in the popover within a few seconds.

### About the Keychain prompt

On first launch macOS asks to allow access to the "Claude Code-credentials" Keychain item. That is the OAuth token Claude Code itself stores; Tokei reads it (read-only) solely to query your quota. Click **Always Allow** to avoid repeat prompts. If you deny it, cost tracking still works — only the quota bars are unavailable, and Tokei won't ask again until you open the popover or hit Refresh.

**Make "Always Allow" survive rebuilds.** By default the app is ad-hoc signed, and macOS ties the Keychain grant to the exact binary — every rebuild re-prompts for your password. To fix this once, create a stable self-signed code-signing certificate named `Tokei Dev`:

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name: `Tokei Dev`, Identity Type: Self-Signed Root, Certificate Type: **Code Signing**
3. Rebuild (`./scripts/bundle.sh` picks it up automatically). Approve the Keychain prompt one last time with **Always Allow** — it now sticks across rebuilds.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Session expired" in popover | Open Claude Code once; it refreshes the token. Tokei never refreshes tokens itself. |
| "No credentials found" | Sign in to Claude Code (`claude` in a terminal). |
| "Keychain access denied" | Re-launch Tokei and approve the Keychain prompt, or delete the app's entry under Keychain Access → login. |
| Quota bars stale / "Offline" | Network issue; history is local and stays intact. Last good snapshot is shown with its timestamp. |
| Launch at Login toggle missing | Only shown when running from an installed `.app` bundle (macOS requirement), not via `swift run`. |
| Costs look off | Compare with `npx ccusage@latest daily`; both read the same JSONL files. |

## Development

```sh
swift run Tokei            # run the app unbundled
swift run TrackerCLI today # CLI over the same core: today|month|daily|quota|scan
swift run TrackerCoreDemo  # assert-based check suite (no XCTest in CLT-only toolchains)
```

### Manual smoke checklist

- [ ] Fresh install: copy `.app` to /Applications, launch, approve Keychain prompt once
- [ ] Menu bar % matches `/usage` inside Claude Code
- [ ] Today's cost within ~1% of `npx ccusage@latest daily`
- [ ] Run a Claude Code prompt in another terminal → popover updates within ~5s
- [ ] Quit + relaunch: state restores fast
- [ ] Wi-Fi off: history intact, quota shows offline state with last snapshot
- [ ] Activity Monitor after 1h idle: ~0% CPU, stable memory
