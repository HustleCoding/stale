# Releasing Stale

## Building a release locally

```
make dist                    # → dist/Stale-<VERSION>.zip + .dmg, universal, ad-hoc signed
make dist SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
make notarize SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   # notarize + staple app and DMG
```

The DMG (`app/dmg.sh`) opens as a "drag Stale to Applications" window with a custom
background and volume icon; the Finder layout step is skipped with a warning if
AppleScript is unavailable. Ad-hoc builds run locally but Gatekeeper warns on
download (right-click → Open).
`make notarize` expects a notarytool keychain profile named `stale`
(`xcrun notarytool store-credentials stale --apple-id … --team-id … --password <app-specific>`).

## Releasing from GitHub Actions

Pushing a `v*` tag (`git tag v1.0.0 && git push --tags`) runs the `release` job in
[`.github/workflows/build.yml`](../.github/workflows/build.yml): it builds the universal
app, signs it with your Developer ID, notarizes with Apple, staples, and attaches
`Stale-<version>.zip`, `.dmg` and `SHA256SUMS.txt` to a GitHub Release.

Add these repository secrets (Settings → Secrets and variables → Actions):

| secret | value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of your **Developer ID Application** certificate + private key: export it from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | the password you chose when exporting the `.p12` |
| `APPLE_ID` | Apple ID e-mail of the developer account |
| `APPLE_TEAM_ID` | 10-character Team ID (the part in parentheses in the certificate name) |
| `APPLE_APP_PASSWORD` | an [app-specific password](https://appleid.apple.com/account/manage) for that Apple ID |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle update-signing key: `generate_keys` (from the Sparkle download) then `generate_keys -x key.txt`; its public half is `SPARKLE_PUBLIC_KEY` in the Makefile |

The release also carries `appcast.xml`, the update feed installed copies read from
`releases/latest/download/appcast.xml` — so the repository (or at least its
releases) must be public.

The certificate is imported into a throw-away keychain on the runner and deleted
afterwards. If the secrets are missing, the release job still publishes an ad-hoc
signed build and marks the release as not notarized.

## Website and Homebrew

The landing page in `site/` is a Cloudflare Worker with static assets; `/download` redirects
to the newest release's DMG. Deploy with `cd site && npx wrangler deploy`.

Homebrew users can install from the cask in this repo:

```
brew tap hustlecoding/stale https://github.com/HustleCoding/stale
brew install --cask stale
```
