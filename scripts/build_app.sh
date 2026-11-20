#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="TourMix"
BUNDLE_ID="com.soundlab.TourMix"
VERSION="1.0.0"
BUILD_NUMBER="1"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
INSTALL_TO_APPLICATIONS=false

for arg in "$@"; do
    case "$arg" in
        --install)
            INSTALL_TO_APPLICATIONS=true
            ;;
        -h|--help)
            echo "Usage: $0 [--install]"
            echo "  --install   Stop running ${APP_NAME} (if any) and install to /Applications/${APP_NAME}.app"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

echo "==> Building ${APP_NAME} (Release)..."
swift build -c release --product "${APP_NAME}"

BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE_PATH="${BIN_DIR}/${APP_NAME}"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Error: Built executable not found at ${EXECUTABLE_PATH}" >&2
    exit 1
fi

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

xattr -cr "dist/${APP_NAME}.app" 2>/dev/null || true

echo "==> Code signing dist/${APP_NAME}.app (${BUNDLE_ID})..."
codesign --force --deep --identifier "${BUNDLE_ID}" --sign - "dist/${APP_NAME}.app"
codesign --verify --verbose=2 "dist/${APP_NAME}.app"

echo "==> Built successfully: ${APP_BUNDLE}"

if [[ "$INSTALL_TO_APPLICATIONS" == true ]]; then
    TARGET_APP="/Applications/${APP_NAME}.app"
    if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
        echo "==> Stopping running ${APP_NAME} process..."
        pkill -x "${APP_NAME}" 2>/dev/null || true
        for _ in {1..20}; do
            if ! pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
    fi

    echo "==> Installing to ${TARGET_APP}..."
    rm -rf "$TARGET_APP"
    ditto "$APP_BUNDLE" "$TARGET_APP"
    echo "==> Installed successfully: ${TARGET_APP}"
fi
