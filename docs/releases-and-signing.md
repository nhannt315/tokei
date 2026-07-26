# Releases, Signing & In-App Updates

How Tokei ships builds, signs them, and updates itself. Read this before
touching `release.yml`, `scripts/bundle.sh`, the signing certificate, or the
`UpdateChecker` / `UpdateInstaller` code.

> **Current signing state (2026-07-26): ad-hoc, local + CI.** The cert-based
> sections below (`Tokei Dev`, `SIGNING_CERT_*` secrets) are **not** the active
> release path — they are kept for local dev (`USE_LOCAL_CERT=1`) and as history.
> Why the change: a self-signed cert names a `certificate leaf` in the
> designated requirement that only the author's Mac has, so on any *other* Mac
> `amfid` refuses to launch it (`error 162`). Ad-hoc's `cdhash` requirement is
> self-contained and launches anywhere after a one-time **System Settings →
> Privacy & Security → Open Anyway** (quarantined `.dmg` installs only; OTA
> updates aren't quarantined and need no action). CI now signs ad-hoc and
> verifies the build is *not* cert-locked. The real fix — Apple notarization —
> is deferred on budget: see `plans/260724-notarization/plan.md`. Everything
> below still documents the mechanics; just read "cert" as the opt-in/local and
> future-Developer-ID path, not today's release path.

## The core problem this solves

Tokei reads the Claude Code OAuth token from the Keychain to show quota. macOS
binds that "Always Allow" grant to the app's **designated requirement**. For an
**ad-hoc** signature that requirement is the binary's own hash:

```
designated => cdhash H"dcd81e40..."
```

Every rebuild changes the hash, so the grant stops matching and macOS
re-prompts for a password — on every local rebuild *and* every OTA update.

Signing with a **certificate** changes the requirement to name the certificate:

```
designated => identifier "com.nhannt315.tokei" and certificate leaf = H"0423dc3c..."
```

That string is identical across every rebuild, every release, and on every
user's machine. Each user approves the Keychain prompt **once**, and it sticks.
This is the entire reason the signing setup exists — not Gatekeeper, not
notarization.

## What does NOT matter here

- **Notarization / Apple Developer ID ($99/yr)** is *not* required. It buys a
  clean first-launch from the downloaded `.dmg`, nothing more. Grant stability
  comes from any stable certificate, including a self-signed one.
- **`spctl -a` reports "rejected"** for the ad-hoc/self-signed bundle. That is
  the *quarantine policy* assessment, not the execution gate. The app runs.
- **Quarantine**: files downloaded programmatically (the OTA path) get **no**
  `com.apple.quarantine` xattr — quarantine is set by the *downloading* app
  (e.g. a browser). So a self-downloaded update relaunches with no Gatekeeper
  prompt. (A user's first install from the browser-downloaded `.dmg` is
  quarantined and needs the usual right-click-Open once.)

Verify any of these with:
```sh
codesign -d -r- /Applications/Tokei.app | grep 'designated =>'
xattr /Applications/Tokei.app        # look for com.apple.quarantine
```

## The signing certificate

A self-signed **Code Signing** root named **`Tokei Dev`**, created in Keychain
Access → Certificate Assistant. Issuer == subject (a true self-signed root),
valid to 2036.

**It is the single point of failure.** If lost, a regenerated cert has a
different leaf hash → the designated requirement changes → **every user
re-approves the Keychain prompt once.** Guard the exported `.p12` and its
password (password manager / encrypted backup). The cert alone is not enough;
you need the `.p12` (cert **+** private key).

### Gotcha: `security find-identity -p codesigning` shows 0 identities

A self-signed cert fails the *codesigning trust policy*, so this lists nothing
— **even though `codesign` signs with it fine.** Do not use
`find-identity -p codesigning` to detect or select this cert. Confirm the cert
works by actually signing:

```sh
printf '#!/bin/sh\n' > /tmp/probe; chmod +x /tmp/probe
codesign --force --sign "Tokei Dev" /tmp/probe && codesign -dv --verbose=2 /tmp/probe 2>&1 | grep Authority
# expect: Authority=Tokei Dev
```

This is why CI selects the cert by its **SHA-1 hash** (read straight from the
cert, policy-independent), not by `find-identity`.

## Local builds

`scripts/bundle.sh` uses `Tokei Dev` when present, else falls back to ad-hoc
(with a warning). It prints the identity and designated requirement it
produced — if you see a `cdhash` requirement, the build went out ad-hoc and
will keep prompting.

```sh
./scripts/bundle.sh
# look for: identity: Tokei Dev
#           designated => identifier "com.nhannt315.tokei" and certificate leaf = H"..."
```

Set `REQUIRE_SIGNING_IDENTITY=1` to make a missing identity a hard error
instead of an ad-hoc fallback (CI does this).

If local builds still go ad-hoc, the identity is not usable in your login
keychain — re-import the `.p12` (see rotation below).

## CI releases (`.github/workflows/release.yml`)

Triggered by pushing a `v*` tag. Steps:

1. **Import signing certificate** — decodes `SIGNING_CERT_P12`, imports into a
   job-scoped keychain (destroyed with the runner), selects the cert by SHA-1
   hash, and **test-signs a probe** to prove it works before continuing.
2. **Build app bundle** — `REQUIRE_SIGNING_IDENTITY=1`, so it fails rather than
   shipping ad-hoc.
3. **Verify signature is certificate-based** — fails the release if the
   requirement contains `cdhash`. A silent ad-hoc release would break every
   user's grant, so this guard is deliberate.
4. Package `.dmg` + `.zip`, create the GitHub Release.

The `.zip` is what the in-app updater downloads (`ditto` preserves the
signature; no `hdiutil` mount needed). The `.dmg` is for manual drag-install.

### Repository secrets

| Secret | Value |
|---|---|
| `SIGNING_CERT_P12` | base64 of the exported `.p12` (cert + private key) |
| `SIGNING_CERT_PASSWORD` | the `.p12` export password |

Both must come from the **same** `.p12`. Anyone who can read these secrets can
sign software as you — treat the `.p12` as a private key.

### Rotating / re-exporting the certificate

Export from Keychain Access → **My Certificates** (not "Certificates" — that
category has no private key) → right-click `Tokei Dev` → Export → `.p12`, set a
password you record. Then:

```sh
base64 -i Tokei-Dev.p12 | gh secret set SIGNING_CERT_P12 --repo nhannt315/tokei
gh secret set SIGNING_CERT_PASSWORD --repo nhannt315/tokei   # prompts, hidden
security import Tokei-Dev.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -f pkcs12   # fix local
rm -P Tokei-Dev.p12
```

Verify the `.p12` before trusting it to a release (this is the exact CI
sequence; run locally):

```sh
KC=/tmp/ci-check.keychain-db; KP=$(uuidgen)
security create-keychain -p "$KP" "$KC" && security unlock-keychain -p "$KP" "$KC"
security import ~/Desktop/Tokei-Dev.p12 -k "$KC" -T /usr/bin/codesign -f pkcs12
security set-key-partition-list -S apple-tool:,apple: -k "$KP" "$KC" >/dev/null
ID=$(security find-certificate -a -c "Tokei Dev" -Z "$KC" | awk '/SHA-1 hash:/{print $3; exit}')
printf '#!/bin/sh\n' > /tmp/pr; chmod +x /tmp/pr
codesign --force --sign "$ID" --keychain "$KC" /tmp/pr && echo "OK"
security delete-keychain "$KC"; rm -f /tmp/pr
```

Regenerating (not just re-exporting) the cert changes the leaf hash — every
user re-approves the Keychain prompt once. Re-exporting the *same* cert does
not.

### `.p12` export gotcha

Modern macOS exports `.p12` files with a `MAC: Iteration 1` header that recent
OpenSSL 3.x flags as "invalid password" even when the password is correct —
`openssl pkcs12` is **not** a reliable validity test here. Trust `security
import` instead (it wrote the file). A cert-only export (default filename
`Certificates.p12`, no `Shrouded Keybag` in the structure) is missing the
private key — re-export from **My Certificates**.

## In-app updates (`Sources/TrackerCore/UpdateChecker.swift`, `UpdateInstaller.swift`)

- **Check**: polls `releases/latest` (unauthenticated, ≤60 req/h/IP) at most
  every 6h from the main poll loop. Compares `tag_name` to the bundle's
  `CFBundleShortVersionString`. Version compare is numeric per component
  (0.1.10 > 0.1.9); `git describe` suffixes are stripped so a dev build is not
  offered the tag it already contains.
- **Notify**: a row in the popover with an Update button (no silent auto-install).
- **Stage**: downloads the `.zip`, `ditto`-unpacks, and refuses any bundle
  whose `CFBundleIdentifier` is not `com.nhannt315.tokei`.
- **Swap**: a detached `/bin/sh` waits for the app to exit, moves the new
  bundle in, and relaunches — keeping the old bundle aside and restoring it if
  the move fails. The app cannot replace itself in-process.

Only surfaces for installed `.app` builds, never `swift run`. Non-admin users
can't write `/Applications`; the installer surfaces a clear error + manual
download link rather than failing silently.

### First release with a `.zip` was v0.1.3

Earlier releases have only a `.dmg`, so `UpdateChecker.decode` returns nil for
them (no zip asset). The OTA path goes live from v0.1.3 onward.

## Verifying a shipped release

```sh
gh release download vX.Y.Z --repo nhannt315/tokei --pattern '*.zip' --dir /tmp/rel
ditto -x -k /tmp/rel/*.zip /tmp/rel/out
codesign -d -r- /tmp/rel/out/Tokei.app | grep 'designated =>'
# must name the cert leaf, NOT cdhash; leaf hash must match the local Tokei Dev cert
codesign --verify --verbose /tmp/rel/out/Tokei.app
```

## Checks

Core logic (version compare, release decode, zip-asset selection) is covered in
`Sources/TrackerCoreDemo/main.swift` — run `swift run TrackerCoreDemo`. The
bundle swap and CI signing are shell-level and verified by the commands above,
not by the check suite.
