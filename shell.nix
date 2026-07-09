let
  pkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixpkgs-unstable.tar.gz";
  }) {};
in

pkgs.mkShell {
  buildInputs = with pkgs; [ flutter androidsdk coreutils bash unzip zip ];

  shellHook = ''
    # Run once: install common Android SDK components and run flutter doctor
    MARKER=.nix-android-setup-done
    if [ ! -f "$PWD/$MARKER" ]; then
      echo "Running nix-shell Android SDK setup (this may take a few minutes)..."
      export NIXPKGS_ACCEPT_ANDROID_SDK_LICENSE=1

      # Ensure we use the nix-provided adb/sdkmanager
      SDKROOT_DIR=$(dirname $(dirname $(which adb) || true) 2>/dev/null)
      if [ -n "$SDKROOT_DIR" ]; then
        export ANDROID_SDK_ROOT="$SDKROOT_DIR"
      fi

      if command -v sdkmanager >/dev/null 2>&1; then
        yes | sdkmanager --licenses >/dev/null 2>&1 || true
        sdkmanager "platform-tools" "build-tools;33.0.0" "platforms;android-33" || true
      else
        echo "sdkmanager not found in shell; please install Android SDK via nixpkgs or your system." 
      fi

      # Run flutter doctor to surface remaining issues
      if command -v flutter >/dev/null 2>&1; then
        flutter doctor || true
      fi

      touch "$PWD/$MARKER"
      echo "nix-shell Android SDK setup finished."
    fi
  '';
}
