# stale

What you use on your Mac, what you don't, and when you last touched it.

`stale` walks a folder (default `~`) on all cores and classifies every file by
**real usage**: it joins the filesystem's modified/created times with macOS
Spotlight's *last opened* metadata (`kMDItemLastUsedDate`, the "Last Opened"
column in Finder), so a PDF you read yesterday counts as used even if you never
edited it, and an app you never launched shows up as never launched.

```
stale  ~  1.9M files, 57G, 3.8s, 41,203 Spotlight last-opened records

When did you last use it?  (by size; last used = max(last opened, modified))
  hot     this week    ████░░░░░░░░░░░░░░░░░░░░░░░░░░   7.8G  14%
  warm    this month   ██████░░░░░░░░░░░░░░░░░░░░░░░░  11.2G  20%
  cold    < 6 months   ███████░░░░░░░░░░░░░░░░░░░░░░░  13.1G  23%
  stale   6-12 months  ███░░░░░░░░░░░░░░░░░░░░░░░░░░░   6.0G  11%
  frozen  > 1 year     ██████████░░░░░░░░░░░░░░░░░░░░  18.9G  33%
  never                 14.4G (created, never opened or modified since)

Reclaimable  (regenerable: node_modules, build output, caches, Xcode, Docker, Trash)
  total 21.3G, of which 12.7G untouched for 30+ days
    4.1G  8mo    ~/Library/Developer/Xcode/DerivedData          xcode
    2.9G  1.2y   ~/repos/old-saas/node_modules                   node_modules
    ...
  → stale trash --older 30d

Forgotten folders  (≥90% of content untouched for 6+ months, ≥50M)
    6.2G  1.8y   ~/Movies/2023-trip                              mostly never opened
    ...

Big files you haven't touched in 6+ months  (≥100M)
    2.1G  1.4y   ~/Downloads/Xcode_15.2.xip                      never opened
```

## Commands

| command | what it does |
| --- | --- |
| `stale [path]` | usage report for a folder (default `~`) |
| `stale ls <path>` | children of a folder by size, each with its last-used age, file count and category |
| `stale apps` | every app in `/Applications` and `~/Applications`, never-launched and least-recently-launched first |
| `stale trash [path]` | move reclaimable, unused folders to the Trash (asks first, never `rm`) |

Options: `--top N`, `--json`, `--atime` (also count file access time as usage),
`--no-spotlight`, `--threads N`, `--no-color`.

`trash` options: `--older 30d|6mo|1y` (default 180d), `--category node_modules,build,venv,cache,xcode,docker`,
`--all` (also trash non-regenerable frozen folders — careful), `--dry-run`, `-y`.

## How "last used" is computed

For every file: `max(Spotlight last opened, modified time[, access time with --atime])`.
Folders take the newest of their contents, so a project touched yesterday is *hot*
even if 95% of its bytes are ancient — that 95% shows up under its `node_modules`
or `dist` instead.

**never opened** = Spotlight has no last-opened date *and* the file hasn't been
modified since it was created (downloaded/generated/copied and never touched again),
and it is older than 30 days.

Recognised categories (treated as leaf "units" in reports):

- `node_modules`, `.venv`/`venv`/`__pycache__`, `dist`/`build`/`target`/`.next`/… (only next to a project manifest)
- `~/Library/Caches/*`, `~/.cache/*`, `~/.npm`, pnpm/yarn/cargo/gradle/go caches, VS Code/Cursor/Chrome/Slack caches
- Xcode: DerivedData, Archives, DeviceSupport, simulators (per device)
- Docker/OrbStack/Colima data, `.Trash`
- `.git`, `*.app`, and macOS bundles (`.photoslibrary`, `.xcodeproj`, `.framework`, …) — shown as one item, never split

## Build

```
make            # → build/stale (clang++, Foundation + CoreServices only)
make install    # → /usr/local/bin/stale
```

Requires Xcode Command Line Tools. No third-party dependencies.

## Distribution

```
make dist                    # → dist/Stale-<VERSION>.zip + .dmg, universal, ad-hoc signed
make dist SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
make notarize SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   # notarize + staple app and DMG
```

Ad-hoc builds run locally but Gatekeeper warns on download (right-click → Open).
`make notarize` expects a notarytool keychain profile named `stale`
(`xcrun notarytool store-credentials stale --apple-id … --team-id … --password <app-specific>`).

### Releasing from GitHub Actions

Pushing a `v*` tag (`git tag v1.0.0 && git push --tags`) runs the `release` job in
[`.github/workflows/build.yml`](.github/workflows/build.yml): it builds the universal
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

The certificate is imported into a throw-away keychain on the runner and deleted
afterwards. If the secrets are missing, the release job still publishes an ad-hoc
signed build and marks the release as not notarized.

## Notes

- Give your terminal **Full Disk Access** (System Settings → Privacy & Security) to
  read `~/Library/Mail`, Safari, Messages, etc.; otherwise they are counted as unreadable.
- Spotlight must be enabled for the volume (`mdutil -s /`). Without it the tool
  falls back to modified time only.
- `trash` uses `NSFileManager.trashItemAtURL`, so everything is recoverable from
  the Trash until you empty it.
- Sizes are allocated bytes (`st_blocks`), so APFS clones and sparse files are
  reported at what they actually occupy.
