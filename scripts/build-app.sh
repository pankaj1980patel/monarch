#!/bin/zsh
# Builds Monarch.app (release) and installs it to ~/Applications.
#
#   scripts/build-app.sh            build + install
#   scripts/build-app.sh --run      build + install + (re)launch
#   scripts/build-app.sh --release  universal (arm64 + x86_64) build, zipped to dist/, not installed
#
# Signing: macOS ties the Accessibility grant to the app's code signature. An ad-hoc
# signature changes on every build, which would make you re-grant Accessibility each
# time. So this script creates a local self-signed "Monarch Local Signing" certificate
# once, in its own keychain (no system password prompt), and signs every build with it.
#
# Release signing and notarization (optional, for --release). With an Apple Developer account:
#   MONARCH_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"   signs with it instead
#   MONARCH_NOTARY_PROFILE=monarch-notary                                 notarizes and staples
# Create the notary profile once with:
#   xcrun notarytool store-credentials monarch-notary --apple-id you@example.com --team-id TEAMID
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

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

cd "$ROOT"
# A failed build must stop here: otherwise the previous binary would be signed and installed
# as if it were new.
build() {   # build [triple]: builds the app, prints nothing on success but warnings
  local args=(-c release --product "$APP_NAME")
  [[ -n "${1:-}" ]] && args+=(--triple "$1")
  echo "→ swift build ${args[*]}"
  local log; log="$(mktemp -t monarch-build)"
  if ! swift build "${args[@]}" > "$log" 2>&1; then
    grep -vE '^\[[0-9]+/[0-9]+\]' "$log" | tail -40
    echo "build failed: nothing installed"
    rm -f "$log"
    exit 1
  fi
  grep -E 'warning:|error:' "$log" | sort -u | head -20 || true
  rm -f "$log"
}
if (( RELEASE )); then
  # Two single-architecture builds joined with lipo: a multi-arch `swift build` needs Xcode.
  BIN="$(mktemp -d)/$APP_NAME"
  for triple in arm64-apple-macosx15.0 x86_64-apple-macosx15.0; do build "$triple"; done
  lipo -create -output "$BIN" \
    "$(swift build -c release --triple arm64-apple-macosx15.0 --show-bin-path)/$APP_NAME" \
    "$(swift build -c release --triple x86_64-apple-macosx15.0 --show-bin-path)/$APP_NAME"
  echo "→ universal binary: $(lipo -archs "$BIN")"
else
  build
  BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
fi
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
# The commit this build is from, for logs and diagnostics reports ("-dirty": uncommitted changes).
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [[ "$COMMIT" != unknown ]] && ! git -C "$ROOT" diff --quiet HEAD -- Sources Package.swift 2>/dev/null; then COMMIT="$COMMIT-dirty"; fi
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
  <key>MonarchCommit</key><string>$COMMIT</string>
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

if (( RELEASE )); then
  mkdir -p "$ROOT/dist"
  ZIP="$ROOT/dist/$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"
  if [[ -n "${MONARCH_DEVELOPER_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$MONARCH_DEVELOPER_ID" --identifier "$BUNDLE_ID" "$STAGE"
    echo "→ signed with \"$MONARCH_DEVELOPER_ID\""
    if [[ -n "${MONARCH_NOTARY_PROFILE:-}" ]]; then
      echo "→ notarizing (this takes a few minutes)"
      ditto -c -k --keepParent "$STAGE" "$ZIP"
      xcrun notarytool submit "$ZIP" --keychain-profile "$MONARCH_NOTARY_PROFILE" --wait
      xcrun stapler staple "$STAGE"
      rm -f "$ZIP"
    else
      echo "  not notarized: set MONARCH_NOTARY_PROFILE to notarize"
    fi
  else
    ensure_identity || true
    HASH=$(security find-identity -p codesigning 2>/dev/null | awk -v id="\"$IDENTITY\"" '$0 ~ id {print $2; exit}')
    if [[ -n "$HASH" ]]; then
      security unlock-keychain -p "$(<"$KEYPASS_FILE")" "$KEYCHAIN"
      codesign --force --options runtime --sign "$HASH" --identifier "$BUNDLE_ID" "$STAGE"
      echo "→ signed with \"$IDENTITY\" (not notarized: users must right-click → Open)"
    else
      codesign --force --sign - --identifier "$BUNDLE_ID" "$STAGE"
      echo "→ ad-hoc signed (not notarized: users must right-click → Open)"
    fi
  fi
  ditto -c -k --keepParent "$STAGE" "$ZIP"
  rm -rf "${STAGE:h}"
  echo "→ $ZIP"
  echo "  SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  exit 0
fi

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
  # SIGUSR1: clean quit for a restart (keeps parked windows parked); launchd doesn't restart it.
  # Wait until it has really exited: a copy opened while the old one runs just leaves.
  if pkill -USR1 -x "$APP_NAME" 2>/dev/null; then
    for _ in $(seq 1 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
  fi
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
