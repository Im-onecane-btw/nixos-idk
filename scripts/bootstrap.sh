#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh — одноразовый запуск: скачивает install.sh и отдаёт ему управление.
#
#  Зачем отдельный файл: когда скрипт получают через `curl ... | sudo bash`,
#  у него нет ни своей папки, ни терминала, поэтому он не может ни прочитать
#  flake рядом, ни задать вопросы. Здесь мы это обходим: качаем архив
#  репозитория, распаковываем и запускаем install.sh уже нормальным процессом.
#
#  Использование (из-под root, интернет обязателен):
#    curl -fsSL https://raw.githubusercontent.com/Im-onecane-btw/nixos-idk/main/scripts/bootstrap.sh | sudo bash
#
#  Всё остальное делает install.sh: включает flakes, копирует конфиг в
#  /etc/nixos, собирает и переключает систему.
# =============================================================================
set -euo pipefail

REPO="${RYOKU_REPO:-https://github.com/Im-onecane-btw/nixos-idk.git}"
BRANCH="${RYOKU_BRANCH:-main}"
DEST="${RYOKU_DEST:-/root/nixos-idk-bootstrap}"

if [ "$(id -u)" -ne 0 ]; then
  echo "нужен root: sudo bash bootstrap.sh" >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "нет curl" >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "нет tar"  >&2; exit 1; }

echo "==> качаю $REPO ($BRANCH)"
rm -rf "$DEST"
mkdir -p "$DEST"
curl -fsSL "${REPO%.git}/archive/refs/heads/$BRANCH.tar.gz" \
  | tar -xz -C "$DEST" --strip-components=1

echo "==> запускаю $DEST/scripts/install.sh"
exec bash "$DEST/scripts/install.sh" "$@"