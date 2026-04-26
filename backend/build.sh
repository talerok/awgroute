#!/usr/bin/env bash
# Сборка amnezia-box (форк sing-box с AmneziaWG поддержкой).
# Клонирует hoaxisr/amnezia-box, собирает с нужными build-tags, кладёт бинарь в backend/amnezia-box.
#
# Usage:
#   backend/build.sh            # обычная сборка
#   FORCE=1 backend/build.sh    # переклонировать src даже если уже есть
#   REF=awg2.0 backend/build.sh # явный git ref (тег/ветка/коммит)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/hoaxisr/amnezia-box.git}"
REF="${REF:-1.12.12-awg}"
SRC_DIR="${SCRIPT_DIR}/src"
OUT_BIN="${SCRIPT_DIR}/amnezia-box"

if [[ "${FORCE:-0}" == "1" ]]; then
  rm -rf "${SRC_DIR}"
fi

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo ">> Cloning ${REPO_URL}@${REF} -> ${SRC_DIR}"
  git clone --depth 1 --branch "${REF}" "${REPO_URL}" "${SRC_DIR}"
else
  echo ">> Reusing existing src in ${SRC_DIR} (use FORCE=1 to re-clone)"
fi

GO_BIN="$(command -v go || true)"
if [[ -z "${GO_BIN}" ]]; then
  if [[ -x /opt/homebrew/bin/go ]]; then
    GO_BIN=/opt/homebrew/bin/go
  elif [[ -x /usr/local/go/bin/go ]]; then
    GO_BIN=/usr/local/go/bin/go
  else
    echo "!! go not found in PATH. Install with: brew install go" >&2
    exit 1
  fi
fi

echo ">> Using $(${GO_BIN} version)"

# Build tags по PLAN.md этап 0:
#   with_gvisor, with_quic, with_dhcp, with_wireguard, with_utls,
#   with_acme, with_clash_api, with_awg
TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_awg"

cd "${SRC_DIR}"
echo ">> Building with tags: ${TAGS}"
CGO_ENABLED=1 "${GO_BIN}" build \
  -tags "${TAGS}" \
  -trimpath \
  -ldflags "-s -w" \
  -o "${OUT_BIN}" \
  ./cmd/sing-box

echo ">> Built: ${OUT_BIN}"
"${OUT_BIN}" version || true
