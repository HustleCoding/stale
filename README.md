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

## Stale.app

The Mac app (`make app`, or the DMG from Releases) indexes the whole disk (`/`)
once and remembers the result in `~/Library/Application Support/Stale/`, so later
launches open instantly from the saved index. The index then keeps itself current
with FSEvents: on launch the app replays what changed on disk since the index was
saved and re-reads only those folders, and while it runs it follows changes live
("Up to date"). A full **Rescan** is still there for when you want it (and happens
by itself if FSEvents lost track — dropped events, a swapped volume, too many
changes). Open a different folder with the folder button (or
`open -a Stale <path>`); each root keeps its own index.

The Overview shows what's on the disk as a two-level segmented ring plus a bar of
recency buckets. The sidebar's *Clean up* group finds space: Safe to delete
(caches, build output, package stores), Duplicates (same content, verified by
SHA-256; the most recently used copy is kept), Leftovers (Library data of apps
that are no longer installed, old iPhone/iPad backups) and Old downloads
(installers whose app is already installed, archives, anything not opened in 30
days), and AI agents (worktrees, caches, logs, old transcripts and local models
left by Codex, Cursor, Claude Code, Conductor and similar tools; a worktree is
preselected only after 14 days untouched with no uncommitted changes and HEAD on
a branch, and models are never preselected). *Review* lists forgotten folders, big unused files, unused apps and what's
in the Trash. Folders expand down to files; Space shows a Quick Look preview,
⌘↓ opens, right-click reveals in Finder or copies the path. Nothing is deleted
without asking — everything goes to the Trash, and only the Trash page's
explicit **Empty Trash…** deletes for good.

On first launch without Full Disk Access, a short sheet explains why it's needed,
opens the right Settings pane (the app icon can be dragged straight into the list)
and closes by itself once access is granted, then indexes. **Help → Grant Full Disk
Access…** brings it back. Updates arrive through [Sparkle](https://sparkle-project.org):
Stale checks daily and installs updates silently in the background; **Stale → Check
for Updates…** checks now.

## Build

```
make            # → build/stale (CLI) + build/Stale.app, universal (arm64 + x86_64)
make ARCHS=arm64  # quicker local build
make install    # → /usr/local/bin/stale + /Applications/Stale.app
```

Requires Xcode Command Line Tools. The only dependency, Sparkle (auto-updates), is
downloaded on first build and checked against a pinned SHA-256. The app icon and
the DMG background are rendered at build time (`app/mkicon.mm`, `app/mkdmgbg.mm`).

## Distribution

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
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle update-signing key: `generate_keys` (from the Sparkle download) then `generate_keys -x key.txt`; its public half is `SPARKLE_PUBLIC_KEY` in the Makefile |

The release also carries `appcast.xml`, the update feed installed copies read from
`releases/latest/download/appcast.xml` — so the repository (or at least its
releases) must be public.

The certificate is imported into a throw-away keychain on the runner and deleted
afterwards. If the secrets are missing, the release job still publishes an ad-hoc
signed build and marks the release as not notarized.

## Notes

- Give your terminal / Stale.app **Full Disk Access** (System Settings → Privacy &
  Security) to read `~/Library/Mail`, Safari, Messages, etc.; otherwise they are
  counted as unreadable and the app shows a banner offering to open that setting.
- Spotlight must be enabled for the volume (`mdutil -s /`). Without it the tool
  falls back to modified time only.
- `trash` uses `NSFileManager.trashItemAtURL`, so everything is recoverable from
  the Trash until you empty it.
- Sizes are allocated bytes (`st_blocks`), so APFS clones and sparse files are
  reported at what they actually occupy.

## Website and Homebrew

The landing page in `site/` is a Cloudflare Worker with static assets; `/download` redirects
to the newest release's DMG. Deploy with `cd site && npx wrangler deploy`.

Homebrew users can install from the cask in this repo:

```
brew tap hustlecoding/stale https://github.com/HustleCoding/stale
brew install --cask stale
```
