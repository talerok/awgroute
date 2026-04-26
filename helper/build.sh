#!/usr/bin/env bash
# Сборка awgroute-helper в release-конфигурации.
#
# Что делает:
#   1. swift build -c release → исполняемый файл в .build/release/awgroute-helper
#   2. Копирует его рядом со скриптом (для удобства последующего include в .app)
#   3. Ad-hoc подпись (Apple Developer ID не требуется для LaunchDaemon, но Gatekeeper
#      на Sequoia ругается без хоть какой-то подписи).
#
# Вызывается build phase'ом Xcode-проекта приложения (см. Этап 7.3) либо вручную при
# разработке helper'а отдельно от приложения.

set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product awgroute-helper

cp ".build/release/awgroute-helper" "./awgroute-helper"
chmod 755 "./awgroute-helper"

# Ad-hoc подпись. На macOS Sequoia/Tahoe бинари без подписи получают всё больше
# проверок; ad-hoc удовлетворяет минимальные требования для запуска из
# /Library/PrivilegedHelperTools/ через launchctl bootstrap.
codesign --sign - --force --timestamp=none "./awgroute-helper"

echo "built: $(pwd)/awgroute-helper ($(stat -f '%z' awgroute-helper) bytes)"
