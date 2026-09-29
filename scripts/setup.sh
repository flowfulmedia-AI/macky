#!/usr/bin/env bash
# One-time preparation of a Mac for building Macky. Everything used here is free.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Macky: pregătire =="

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ Lipsește Xcode complet (nu doar Command Line Tools)."
  echo "  Instalează Xcode gratuit din App Store, deschide-l o dată, apoi rulează:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi
echo "✓ $(xcodebuild -version | head -1)"

if ! command -v xcodegen >/dev/null; then
  if ! command -v brew >/dev/null; then
    echo "✗ Lipsește Homebrew (necesar pentru xcodegen). Instalează-l de pe https://brew.sh și rulează din nou."
    exit 1
  fi
  echo "→ Instalez xcodegen…"
  brew install xcodegen
fi
echo "✓ xcodegen $(xcodegen --version 2>/dev/null | tail -1)"

./scripts/create-signing-identity.sh

echo
echo "Gata! Acum rulează: make run"
