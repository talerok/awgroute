#!/usr/bin/env bash
# Удобный лаунчер dev-сборки AwgRoute.
# Собирает (если нужно) и открывает .app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT}/app"
APP="${APP_DIR}/build/Build/Products/Debug/AwgRoute.app"

if [[ ! -d "${APP}" || "${1:-}" == "--rebuild" ]]; then
  echo ">> Building AwgRoute (Debug)…"
  ( cd "${APP_DIR}" && xcodebuild \
      -project AwgRoute.xcodeproj \
      -scheme AwgRoute \
      -configuration Debug \
      -derivedDataPath build \
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      | tail -5 )
fi

# AWGROUTE_BACKEND env позволяет переопределить путь к amnezia-box, если нужно.
echo ">> Opening ${APP}"
open -W -a "${APP}" &
echo "(closed when app exits)"
