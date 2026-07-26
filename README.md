# Tokei

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-donate-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/mrx315)

*Tokei* (時計) is Japanese for "clock" — and it doubles as **to**ken + **kei** (計, "meter/gauge"). A clock for your tokens, sitting in the menu bar.

macOS menu bar app that tracks your Claude Code usage: today's and this month's token cost per model (from local transcripts) and your remaining 5-hour / weekly quota (from Anthropic's usage endpoint).

The menu bar shows remaining session quota (e.g. `82%`); the popover shows quota bars with reset times, per-model cost for today and this month, and a Launch at Login toggle.

## Requirements

- macOS 14+
- Swift 6 toolchain (Command Line Tools are enough — no Xcode needed)
- Claude Code installed and signed in

## Install

### From a release (.dmg)

Download the latest `Tokei-*.dmg` from [Releases](https://github.com/nhannt315/tokei/releases), open it, and drag Tokei to Applications.

Tokei isn't signed with an Apple Developer ID (that needs a paid account), so on first launch macOS says it "cannot be opened because Apple cannot check it for malicious software." To allow it:

1. Try to open Tokei once (the warning appears).
2. **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Tokei message.
3. Confirm. Tokei launches and won't ask again.

You only do this once per install. In-app updates download and launch on their own — no repeat of this step.

### From source

```sh
./scripts/bundle.sh
cp -R dist/Tokei.app /Applications/
open /Applications/Tokei.app
```

## CLI

The app bundle ships with a CLI over the same core. Put it on your PATH:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/Tokei.app/Contents/MacOS/tokei-cli ~/.local/bin/tokei
tokei today    # also: month | daily | quota | scan
```

If `~/.local/bin` isn't on your `PATH`, either add it in your shell profile or symlink into `/usr/local/bin` instead (needs `sudo`).

## How it works

- **Usage/cost**: parses `~/.claude/projects/**/*.jsonl` transcripts locally. Streaming placeholder records are deduped by message id; rescans are incremental (per-file offsets), so refreshes are cheap. Pricing comes from LiteLLM's model price catalog, with a bundled snapshot as offline fallback.
- **Quota**: reads Claude Code's OAuth token from the macOS Keychain (`Claude Code-credentials`) and polls `api.anthropic.com/api/oauth/usage` every 5 minutes. Nothing else leaves your machine.
- **Live updates**: FSEvents watch on the projects directory — new Claude Code activity shows up in the popover within a few seconds.

### About the Keychain prompt

On first launch macOS asks to allow access to the "Claude Code-credentials" Keychain item. That is the OAuth token Claude Code itself stores; Tokei reads it (read-only) solely to query your quota. Click **Always Allow** to avoid repeat prompts. If you deny it, cost tracking still works — only the quota bars are unavailable, and Tokei won't ask again until you open the popover or hit Refresh.

Tokei reads the token through `/usr/bin/security` (a stable Apple binary) so the grant binds to it rather than to Tokei's own signature, which keeps re-prompts rare. Because releases are ad-hoc signed (no Apple Developer ID yet), the grant isn't perfectly stable across updates — but it won't spam you: a denied or timed-out read backs off until you next open the popover.

**Optional (local dev only): a stable grant via a self-signed cert.** If you build locally a lot and want the grant to stick perfectly, create a `Tokei Dev` code-signing certificate (Keychain Access → Certificate Assistant → Create a Certificate → Self-Signed Root, type **Code Signing**), then build with `USE_LOCAL_CERT=1 ./scripts/bundle.sh`. Do **not** use this for anything you distribute: a self-signed cert makes the app fail to launch on other Macs (`amfid` "error 162"). It's purely a local convenience.

### Signing releases

Releases are **ad-hoc signed** — Tokei has no Apple Developer ID (that needs a paid account). Ad-hoc builds run on any Mac after a one-time [Open Anyway](#from-a-release-dmg); the release workflow verifies the build is ad-hoc (portable) and not accidentally tied to a local certificate.

> Notarization (the proper fix — no Open Anyway, works everywhere silently) is planned for when an Apple Developer ID is available. Signing and release maintenance details are in [`docs/releases-and-signing.md`](docs/releases-and-signing.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Session expired" in popover | Open Claude Code once; it refreshes the token. Tokei never refreshes tokens itself. |
| "No credentials found" | Sign in to Claude Code (`claude` in a terminal). |
| "Keychain access denied" | Re-launch Tokei and approve the Keychain prompt, or delete the app's entry under Keychain Access → login. |
| Quota bars stale / "Offline" | Network issue; history is local and stays intact. Last good snapshot is shown with its timestamp. |
| Launch at Login toggle missing | Only shown when running from an installed `.app` bundle (macOS requirement), not via `swift run`. |
| Costs look off | Compare with `npx ccusage@latest daily`; both read the same JSONL files. |

## Support

If Tokei is useful to you, you can support development on [Buy Me a Coffee](https://buymeacoffee.com/mrx315). Entirely voluntary — everything here is free and open source.

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
