#!/usr/bin/env bash
# Builds Macky (Release), installs it to ~/Applications/Macky.app and starts it.
# Always installing to the same place with the same signature keeps macOS permissions stable.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNING_IDENTITY="Macky Local Signing"
INSTALL_DIRECTORY="$HOME/Applications"
BUILD_LOG="build/xcodebuild.log"

command -v xcodegen >/dev/null || { echo "Lipsește xcodegen. Rulează întâi: make setup"; exit 1; }
mkdir -p build

./scripts/make-icon.sh

echo "→ Generez proiectul Xcode…"
xcodegen generate --quiet

signing_overrides=()
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
  echo "⚠️  Nu găsesc certificatul \"$SIGNING_IDENTITY\"; semnez ad-hoc."
  echo "   macOS îți va cere permisiunile din nou după fiecare build. Rezolvare: make setup"
  signing_overrides=(CODE_SIGN_IDENTITY=-)
fi

echo "→ Compilez (prima dată durează mai mult: se descarcă WhisperKit)…"
if ! xcodebuild \
    -project Macky.xcodeproj \
    -scheme Macky \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    ${signing_overrides[@]+"${signing_overrides[@]}"} \
    build > "$BUILD_LOG" 2>&1; then
  echo "✗ Compilarea a eșuat. Primele erori:"
  grep -E "error:" "$BUILD_LOG" | head -30 || tail -40 "$BUILD_LOG"
  echo "Log complet: $BUILD_LOG"
  exit 1
fi

BUILT_APPLICATION="build/DerivedData/Build/Products/Release/Macky.app"
echo "→ Instalez în $INSTALL_DIRECTORY/Macky.app…"
pkill -x Macky 2>/dev/null || true
mkdir -p "$INSTALL_DIRECTORY"
rm -rf "$INSTALL_DIRECTORY/Macky.app"
ditto "$BUILT_APPLICATION" "$INSTALL_DIRECTORY/Macky.app"
# Finder and the Dock cache icons; this makes them show the new one.
touch "$INSTALL_DIRECTORY/Macky.app"

echo "→ Pornesc Macky. Iconița apare în bara de meniu, sus-dreapta."
open "$INSTALL_DIRECTORY/Macky.app"
