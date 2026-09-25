#!/bin/bash
# Builds the Stale installer DMG: the app on the left, an Applications alias on the
# right, a "drag to Applications" background and the Stale icon as the volume icon.
#   dmg.sh <Stale.app> <background.tiff> <Stale.icns> <out.dmg>
#
# Finder layout is applied through AppleScript on a mounted read-write image; if
# that fails (e.g. a locked-down CI runner) the DMG is still produced with Finder's
# default layout so the build never blocks on cosmetics.
set -euo pipefail

APP=$1 BG=$2 ICNS=$3 OUT=$4
VOL="Stale"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/stale-dmg.XXXXXX")
RW="$STAGE/rw.dmg"
MNT=""
trap '[ -n "$MNT" ] && hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/root/.background"
cp -R "$APP" "$STAGE/root/"
ln -s /Applications "$STAGE/root/Applications"
cp "$BG" "$STAGE/root/.background/background.tiff"

# Size: app + 20 MB headroom (HFS+ so Finder metadata such as icon positions sticks).
SIZE_KB=$(( $(du -sk "$STAGE/root" | cut -f1) + 20480 ))
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE/root" -ov -fs HFS+ \
  -format UDRW -size "${SIZE_KB}k" "$RW"
# Mount under /Volumes (Finder only scripts disks it can see); the volume may get a
# " 1" suffix if a "Stale" volume is already mounted, so read the real mount point.
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -o '/Volumes/.*' | tail -1)
[ -d "$MNT" ] || { echo "dmg.sh: could not mount $RW" >&2; exit 1; }
VOL=$(basename "$MNT")

APP_NAME=$(basename "$APP")
if ! osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set opts to the icon view options of container window
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set label position of opts to bottom
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME" of container window to {165, 200}
    set position of item "Applications" of container window to {495, 200}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "dmg.sh: warning: Finder layout not applied (AppleScript failed); using default layout" >&2
fi

# Volume icon goes on last: Finder drops a pre-existing .VolumeIcon.icns when it
# first opens the window above.
cp "$ICNS" "$MNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MNT" || true            # "has custom icon" flag on the volume
  SetFile -a V "$MNT/.VolumeIcon.icns" || true
fi
sync
hdiutil detach -quiet -force "$MNT"

rm -f "$OUT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
