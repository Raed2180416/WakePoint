#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." >/dev/null && pwd)
MARKER="$ROOT_DIR/.nix-android-setup-done"

if [ -f "$MARKER" ]; then
  echo "Android SDK setup already completed (marker present)."
  exit 0
fi

export NIXPKGS_ACCEPT_ANDROID_SDK_LICENSE=1

SDKROOT_DIR=""
if command -v adb >/dev/null 2>&1; then
  SDKROOT_DIR=$(dirname $(dirname $(which adb))) || true
  export ANDROID_SDK_ROOT="$SDKROOT_DIR"
fi

if command -v sdkmanager >/dev/null 2>&1; then
  echo "Accepting SDK licenses (non-interactive)..."
  yes | sdkmanager --licenses || true

  echo "Installing platform-tools, build-tools;33.0.0, platforms;android-33"
  sdkmanager "platform-tools" "build-tools;33.0.0" "platforms;android-33" || true
else
  echo "sdkmanager not found in PATH. Ensure you are running inside the nix-shell with androidsdk in buildInputs."
  exit 1
fi

if command -v flutter >/dev/null 2>&1; then
  echo "Running flutter doctor..."
  flutter doctor || true
fi

touch "$MARKER"
echo "Android SDK setup completed."
