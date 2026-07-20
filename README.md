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

**Make "Always Allow" survive rebuilds and updates.** macOS binds the grant to the app's *designated requirement*. For an ad-hoc signed build that requirement is the binary's own hash:

```
# designated => cdhash H"dcd81e40641705922bec1d262964b02d68fdf609"
```

Every rebuild produces a different hash, so the grant no longer matches and macOS asks for your password again. Signing with a certificate changes the requirement to name the *certificate* instead, which is stable across rebuilds and OTA updates. Create one once:

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name: `Tokei Dev`, Identity Type: Self-Signed Root, Certificate Type: **Code Signing**
3. Rebuild (`./scripts/bundle.sh` picks it up automatically). Approve the Keychain prompt one last time with **Always Allow** — it now sticks.

`bundle.sh` prints the identity and designated requirement it produced; if you see a `cdhash` requirement, the build is still ad-hoc and will keep prompting.

### Signing releases in CI

In-app updates are signed builds too, so CI must use the *same* certificate — an ad-hoc release would invalidate the grant for everyone who installs it. The release workflow fails rather than shipping an unsigned build.

Export the identity and add it to the repository secrets:

```sh
# Keychain Access → right-click "Tokei Dev" → Export… → .p12 (set a password)
base64 -i Tokei-Dev.p12 | pbcopy   # paste as SIGNING_CERT_P12
```

| Secret | Value |
|---|---|
| `SIGNING_CERT_P12` | base64 of the exported `.p12` |
| `SIGNING_CERT_PASSWORD` | the password set during export |

The workflow imports it into a temporary keychain that is discarded with the runner. Treat the `.p12` as a private key: anyone who can read those secrets can sign software as you. Rotate it by creating a new certificate and replacing both secrets — users then approve the Keychain prompt once more, since the requirement changed.

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
