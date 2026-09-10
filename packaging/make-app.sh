#!/bin/bash
# Build "PDF Music Breakout.app", a double-clickable launcher for the review UI.
#
# The app is a thin wrapper: it finds the installed pdf-music-breakout command
# and runs its --serve mode, which opens the review screen in your browser.
# Install the command first (brew, uv tool, or pipx), then run this.
#
#   ./packaging/make-app.sh                 -> ~/Applications
#   ./packaging/make-app.sh /Applications
#
set -euo pipefail

DEST="${1:-$HOME/Applications}"
APP="$DEST/PDF Music Breakout.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HERE/../pyproject.toml" | head -1)"
VERSION="${VERSION:-0.1.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>PDF Music Breakout</string>
  <key>CFBundleDisplayName</key>        <string>PDF Music Breakout</string>
  <key>CFBundleIdentifier</key>         <string>io.github.sandinak.pdf-music-breakout</string>
  <key>CFBundleVersion</key>            <string>$VERSION</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleExecutable</key>         <string>launcher</string>
  <key>LSMinimumSystemVersion</key>     <string>11.0</string>
  <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

# Finder launches apps with a bare PATH, so look where installers actually put
# things rather than trusting the environment.
cat > "$APP/Contents/MacOS/launcher" <<'LAUNCH'
#!/bin/bash
set -uo pipefail

for candidate in \
  "$HOME/.local/bin/pdf-music-breakout" \
  /opt/homebrew/bin/pdf-music-breakout \
  /usr/local/bin/pdf-music-breakout \
  "$HOME/.local/share/uv/tools/pdf-music-breakout/bin/pdf-music-breakout"
do
  if [ -x "$candidate" ]; then
    exec "$candidate" --serve
  fi
done

if CLI="$(command -v pdf-music-breakout 2>/dev/null)"; then
  exec "$CLI" --serve
fi

osascript -e 'display alert "PDF Music Breakout is not installed" message "Install the command first, then open this app again.

    uv tool install git+https://github.com/sandinak/pdf-music-breakout

or

    brew install https://raw.githubusercontent.com/sandinak/pdf-music-breakout/main/Formula/pdf-music-breakout.rb" as critical' >/dev/null 2>&1
exit 1
LAUNCH

chmod +x "$APP/Contents/MacOS/launcher"

# Let the Finder notice the new bundle straight away.
touch "$APP"

echo "Built: $APP"
if ! command -v pdf-music-breakout >/dev/null 2>&1 \
   && [ ! -x "$HOME/.local/bin/pdf-music-breakout" ] \
   && [ ! -x /opt/homebrew/bin/pdf-music-breakout ]; then
  echo
  echo "Note: the pdf-music-breakout command isn't on PATH yet. Install it with"
  echo "      one of these, then the app will find it:"
  echo "        uv tool install git+https://github.com/sandinak/pdf-music-breakout"
  echo "        brew install https://raw.githubusercontent.com/sandinak/pdf-music-breakout/main/Formula/pdf-music-breakout.rb"
fi
echo
echo "Open it from the Finder, or run:  open -a 'PDF Music Breakout'"
