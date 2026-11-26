#!/bin/zsh
# Builds Monarch.app (release) and installs it to ~/Applications.
#
#   scripts/build-app.sh            build + install
#   scripts/build-app.sh --run      build + install + (re)launch
#
# Signing: macOS ties the Accessibility grant to the app's code signature. An ad-hoc
# signature changes on every build, which would make you re-grant Accessibility each
# time. So this script creates a local self-signed "Monarch Local Signing" certificate
# once, in its own keychain (no system password prompt), and signs every build with it.
set -euo pipefail

ROOT=${0:A:h:h}
APP_NAME=Monarch
BUNDLE_ID=dev.monarch.Monarch
VERSION=0.1.0
DEST="$HOME/Applications/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/Monarch"
KEYCHAIN="$SUPPORT/signing.keychain-db"
KEYPASS_FILE="$SUPPORT/signing.pass"
IDENTITY="Monarch Local Signing"

cd "$ROOT"
echo "→ swift build -c release"
# A failed build must stop here: otherwise the previous binary would be signed and installed
# as if it were new.
BUILD_LOG="$(mktemp -t monarch-build)"
if ! swift build -c release --product "$APP_NAME" > "$BUILD_LOG" 2>&1; then
  grep -vE '^\[[0-9]+/[0-9]+\]' "$BUILD_LOG" | tail -40
  echo "build failed: nothing installed"
  rm -f "$BUILD_LOG"
  exit 1
fi
grep -E 'warning:|error:' "$BUILD_LOG" | sort -u | head -20 || true
rm -f "$BUILD_LOG"
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "build failed: no binary"; exit 1; }

# --- signing identity (one time) -------------------------------------------------
ensure_identity() {
  mkdir -p "$SUPPORT"
  if [[ ! -f "$KEYPASS_FILE" ]]; then
    (umask 077; openssl rand -hex 24 > "$KEYPASS_FILE")
  fi
  local pass; pass=$(<"$KEYPASS_FILE")
  if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$pass" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"            # no auto-lock
  fi
  security unlock-keychain -p "$pass" "$KEYCHAIN"
  if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "→ creating local signing certificate \"$IDENTITY\""
    local tmp; tmp=$(mktemp -d)
    cat > "$tmp/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    # macOS's importer only reads the legacy PKCS#12 ciphers (OpenSSL 3 defaults to AES).
    openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
      -passout pass:monarch -out "$tmp/id.p12" 2>/dev/null \
      || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
           -passout pass:monarch -out "$tmp/id.p12"
    security import "$tmp/id.p12" -k "$KEYCHAIN" -P monarch -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$KEYCHAIN" >/dev/null
    rm -rf "$tmp"
  fi
}

# --- bundle ----------------------------------------------------------------------
echo "→ assembling $APP_NAME.app"
STAGE=$(mktemp -d)/$APP_NAME.app
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Library/LaunchAgents"
cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
strip -x "$STAGE/Contents/MacOS/$APP_NAME"
cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Launch agent: starts Monarch at login and restarts it after a crash, not after Quit.
# Registered from the app's menu (Launch at Login) with SMAppService.
cat > "$STAGE/Contents/Library/LaunchAgents/$BUNDLE_ID.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID.agent</string>
  <key>BundleProgram</key><string>Contents/MacOS/$APP_NAME</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$BUNDLE_ID</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

ensure_identity || true
# codesign only sees keychains in the user's search list. Adding ours is a one-time step
# you run yourself (the script never changes your keychain settings):
#   security list-keychains -d user -s ~/Library/Keychains/login.keychain-db "$KEYCHAIN"
HASH=$(security find-identity -p codesigning 2>/dev/null | awk -v id="\"$IDENTITY\"" '$0 ~ id {print $2; exit}')
if [[ -n "$HASH" ]]; then
  security unlock-keychain -p "$(<"$KEYPASS_FILE")" "$KEYCHAIN"
  codesign --force --options runtime --sign "$HASH" --identifier "$BUNDLE_ID" "$STAGE"
  echo "→ signed with \"$IDENTITY\" (Accessibility permission survives rebuilds)"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$STAGE"
  echo "→ ad-hoc signed: macOS will ask for Accessibility again after each rebuild."
  echo "  To make the permission stick, run once:"
  echo "    security list-keychains -d user -s ~/Library/Keychains/login.keychain-db \"$KEYCHAIN\""
fi

# --- install ---------------------------------------------------------------------
# Is Launch at Login (the login agent) on? Asked of the installed copy, before replacing it.
AGENT_ON=0
if [[ -x "$DEST/Contents/MacOS/$APP_NAME" ]] && "$DEST/Contents/MacOS/$APP_NAME" --login-status 2>/dev/null | grep -q "login agent: enabled"; then
  AGENT_ON=1
fi
if [[ "${1:-}" == "--run" || $AGENT_ON == 1 ]]; then
  pkill -HUP -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true    # SIGHUP: clean quit for a restart (keeps parked windows parked); launchd doesn't restart it
fi
mkdir -p "$HOME/Applications"
# Update in place (same folder): the login agent's background-item record points at this
# folder, and launchd refuses to start a bundle that was deleted and re-created.
if [[ -d "$DEST" ]]; then
  rsync -a --delete "$STAGE/" "$DEST/"
  rm -rf "${STAGE:h}"
else
  mv "$STAGE" "$DEST"
fi
echo "→ installed $DEST ($(du -sh "$DEST" | cut -f1))"
codesign -dr - "$DEST" 2>&1 | sed -n 's/^designated => /  designated requirement: /p'

if [[ $AGENT_ON == 1 || "${1:-}" == "--run" ]]; then
  # With Launch at Login on, the opened copy registers the login agent again (launchd pins the
  # agent to the code it was registered with and won't start a rebuilt one until then); the
  # agent's copy then starts from the new build and takes over, so crash restarts stay on.
  open "$DEST"
  echo "→ launched"
fi
