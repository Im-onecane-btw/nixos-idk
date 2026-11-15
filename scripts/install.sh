#!/usr/bin/env bash
# =============================================================================
#  install.sh — разворачивает этот флейк на уже установленном NixOS.
#
#  Сценарий: поставил NixOS графическим установщиком (UEFI, пользователь
#  steelium, без GNOME/KDE) -> загрузился -> git clone -> запустил скрипт.
#  Скрипт сам разложит файлы в /etc/nixos и пересоберёт систему с Ryoku,
#  NVIDIA legacy_580 и ядром CachyOS.
#
#  Что делает:
#    1. проверяет, что это NixOS в UEFI и что хватает места
#    2. делает бэкап текущего /etc/nixos в /var/backups/nixos-bootstrap/<дата>
#    3. копирует конфиг (из папки рядом со скриптом или из git)
#    4. сохраняет/генерирует hardware-configuration.nix
#    5. создаёт secrets/tg-ws-proxy-secret, если его нет
#    6. собирает поколение (build), и только потом переключается (switch)
#       если сборка с ядром CachyOS упала — предложит собрать с обычным ядром
#    7. проверяет Ryoku, Wayland-сессии, NVIDIA и предлагает задать пароли
#
#  Использование:
#    sudo bash scripts/install.sh
#    sudo bash scripts/install.sh --repo https://github.com/Minish777/nixos-idk.git
#    sudo bash scripts/install.sh --dry-run
#    sudo bash scripts/install.sh --build-only
#    sudo bash scripts/install.sh --reset-lock
#
#  Флаги:
#    --repo URL      клонировать конфиг из git вместо папки рядом со скриптом
#    --branch NAME   ветка для --repo
#    --host NAME     имя nixosConfiguration: nixos (CachyOS-ядро, по умолчанию)
#                    или nixos-stable-kernel (обычное ядро nixpkgs)
#    --user NAME     имя пользователя (по умолчанию: steelium)
#    --build-only    собрать, но не переключать систему
#    --reset-lock    удалить flake.lock и зафиксировать inputs заново
#    --no-passwords  не предлагать смену паролей
#    --dry-run       только показать план, ничего не менять
#    -y, --yes       без вопросов
#    -h, --help      эта справка
# =============================================================================
set -euo pipefail

FLAKE_DIR=/etc/nixos
BACKUP_DIR=/var/backups/nixos-bootstrap
HOST=nixos
TARGET_USER=steelium
REPO_URL=""
BRANCH=""
DRY_RUN=0
ASSUME_YES=0
BUILD_ONLY=0
SKIP_PASSWORDS=0
RESET_LOCK=0

# --- вывод -------------------------------------------------------------------
if [ -t 1 ]; then
  C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_YEL=""; C_RED=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0; }

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO_URL="${2:?--repo требует URL}"; shift 2 ;;
    --branch)      BRANCH="${2:?--branch требует имя}"; shift 2 ;;
    --host)        HOST="${2:?--host требует имя}"; shift 2 ;;
    --user)        TARGET_USER="${2:?--user требует имя}"; shift 2 ;;
    --build-only)  BUILD_ONLY=1; shift ;;
    --reset-lock)  RESET_LOCK=1; shift ;;
    --no-passwords) SKIP_PASSWORDS=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     usage ;;
    *)             die "неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd)"
LOCAL_ROOT="$(cd -- "$SELF_DIR/.." && pwd)"

# --- root --------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 \
    || die "нужен root, а sudo не найден — запусти скрипт из-под root"
  log "нужен root, перезапускаю через sudo"
  exec sudo -- bash "$SELF_DIR/$(basename -- "$SELF")" "${ORIG_ARGS[@]}"
fi

# --- проверки хоста ----------------------------------------------------------
[ -e /etc/NIXOS ] || die "это не NixOS (/etc/NIXOS не найден)"
[ -d /sys/firmware/efi ] || die "система загружена в BIOS/CSM, а конфиг использует systemd-boot — нужна UEFI-установка"

avail="$(df -Pk /nix 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${avail:-}" ] && [ "$avail" -lt 20971520 ]; then
  warn "на /nix меньше 20 GiB свободно ($((avail / 1024 / 1024)) GiB) — Ryoku тянет много, может не хватить"
fi

grep -qm1 '^flags.*\bavx2\b' /proc/cpuinfo \
  || warn "у CPU нет AVX2, а host nixos собирает ядро cachyos-bore-x86_64-v3 — используй --host nixos-stable-kernel"

awk '$2=="/boot"{found=1} END{exit !found}' /proc/mounts \
  || warn "/boot не смонтирован отдельно — проверь, что ESP на месте, иначе systemd-boot не установится"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  warn "пользователя '$TARGET_USER' пока нет — он появится после пересборки (или поменяй users.users в configuration.nix)"
fi

# --- источник конфига --------------------------------------------------------
TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if [ -n "$REPO_URL" ]; then
  command -v git >/dev/null 2>&1 || die "для --repo нужен git"
  TMP_DIR="$(mktemp -d)"
  log "клонирую $REPO_URL"
  if [ -n "$BRANCH" ]; then
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP_DIR/src"
  else
    git clone --depth 1 "$REPO_URL" "$TMP_DIR/src"
  fi
  SRC="$TMP_DIR/src"
elif [ -f "$LOCAL_ROOT/flake.nix" ]; then
  SRC="$LOCAL_ROOT"
else
  die "рядом со скриптом нет flake.nix; укажи --repo URL"
fi

[ -f "$SRC/configuration.nix" ] || die "в $SRC нет configuration.nix"

log "источник конфига: $SRC"
log "цель: $FLAKE_DIR  (host: $HOST)"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF

План (--dry-run, ничего не меняется):
  1. бэкап $FLAKE_DIR -> $BACKUP_DIR/<дата>
  2. копирование $SRC -> $FLAKE_DIR (без .git)
  3. hardware-configuration.nix: сохранить существующий или сгенерировать
  4. secrets/tg-ws-proxy-secret: создать, если его нет
  5. flake.lock: $([ "$RESET_LOCK" -eq 1 ] && echo "удалить (--reset-lock)" || echo "сохранить (создастся при первой сборке)")
  6. nixos-rebuild build --flake $FLAKE_DIR#$HOST (с кэшами CachyOS + Ryoku)
$( [ "$BUILD_ONLY" -eq 1 ] && echo "  7. (--build-only: switch пропускается)" || echo "  7. nixos-rebuild switch --flake $FLAKE_DIR#$HOST" )
  8. при падении сборки — предложение собрать с обычным ядром (host nixos-stable-kernel)
  9. проверка ryoku, Wayland-сессий, NVIDIA + пароли

EOF
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  printf 'Продолжить? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die "отменено" ;; esac
fi

# --- бэкап -------------------------------------------------------------------
mkdir -p "$FLAKE_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
backup="$BACKUP_DIR/$ts"
mkdir -p "$backup"
if [ -n "$(ls -A "$FLAKE_DIR" 2>/dev/null || true)" ]; then
  log "бэкап $FLAKE_DIR -> $backup"
  cp -a "$FLAKE_DIR"/. "$backup"/
fi

had_hw=0
if [ -s "$FLAKE_DIR/hardware-configuration.nix" ]; then had_hw=1; fi

# --- копирование -------------------------------------------------------------
SRC_REAL="$(readlink -f "$SRC")"
FLAKE_REAL="$(readlink -f "$FLAKE_DIR")"
if [ "$SRC_REAL" = "$FLAKE_REAL" ]; then
  log "конфиг уже лежит в $FLAKE_DIR — копирование пропущено"
else
  log "копирую конфиг в $FLAKE_DIR"
  find "$FLAKE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  cp -a "$SRC"/. "$FLAKE_DIR"/
fi
# .git в /etc/nixos заставил бы Nix видеть только tracked-файлы,
# а hardware-configuration.nix как раз untracked — убираем (копия есть в бэкапе).
rm -rf "$FLAKE_DIR/.git"

# --- hardware-configuration.nix ---------------------------------------------
if [ "$had_hw" -eq 1 ]; then
  log "сохраняю существующий hardware-configuration.nix"
  cp -a "$backup/hardware-configuration.nix" "$FLAKE_DIR/hardware-configuration.nix"
fi
if [ ! -s "$FLAKE_DIR/hardware-configuration.nix" ]; then
  log "генерирую hardware-configuration.nix"
  nixos-generate-config --show-hardware-config > "$FLAKE_DIR/hardware-configuration.nix"
fi

# Секреты живут вне git (/etc/nixos/secrets, см. .gitignore), но нужны
# tg-ws-proxy в рантайме — после очистки каталога возвращаем их из бэкапа.
if [ -d "$backup/secrets" ]; then
  log "возвращаю secrets/ из бэкапа"
  mkdir -p "$FLAKE_DIR/secrets"
  cp -a "$backup/secrets"/. "$FLAKE_DIR/secrets"/
  chmod 700 "$FLAKE_DIR/secrets"
  find "$FLAKE_DIR/secrets" -type f -exec chmod 600 -- {} + 2>/dev/null || true
fi

if [ ! -s "$FLAKE_DIR/secrets/tg-ws-proxy-secret" ]; then
  log "создаю secrets/tg-ws-proxy-secret (случайные 16 байт)"
  mkdir -p "$FLAKE_DIR/secrets"
  ( umask 077; head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' \
      > "$FLAKE_DIR/secrets/tg-ws-proxy-secret" )
fi
chmod 700 "$FLAKE_DIR/secrets"
chmod 600 "$FLAKE_DIR/secrets/tg-ws-proxy-secret" 2>/dev/null || true

# --- lock --------------------------------------------------------------------
# lock удаляем только по явному --reset-lock: иначе повторный запуск скрипта
# не будет каждый раз тянуть другие версии Ryoku/nixpkgs.
if [ "$RESET_LOCK" -eq 1 ]; then
  rm -f "$FLAKE_DIR/flake.lock"
  log "flake.lock удалён — inputs будут зафиксированы заново"
elif [ -f "$FLAKE_DIR/flake.lock" ]; then
  log "flake.lock сохранён (--reset-lock, чтобы обновить inputs)"
else
  log "flake.lock будет создан при первой сборке"
fi

# --- сборка ------------------------------------------------------------------
export NIX_CONFIG="experimental-features = nix-command flakes"
export NIXPKGS_ALLOW_UNFREE=1

# Бинарные кэши нужны уже на ПЕРВОЙ сборке: nix.settings из нового конфига
# начнёт действовать только после switch. Ключи держи в синхроне с
# modules/hardware/kernel-cachy.nix и модулем Ryoku (binaryCache).
NIX_CACHE_ARGS=(
  --option extra-substituters "https://cache.lantian.pub/lantian https://ryotunes.cachix.org"
  --option extra-trusted-public-keys "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ= ryotunes.cachix.org-1:QNocajCsVm/IAMb8LPOWJi72XwqiexW9ec0UqeXLpGs="
)

cd "$FLAKE_DIR"

log "сборка поколения (build, система пока не меняется)"
build_ok=0
for attempt in 1 2; do
  log "попытка $attempt: host $HOST"
  if nixos-rebuild build --flake "$FLAKE_DIR#$HOST" "${NIX_CACHE_ARGS[@]}"; then
    build_ok=1
    break
  fi

  # Самая частая причина падения — nvidia legacy_580 против нового ядра
  # CachyOS. Для этого в флейке есть второй host с обычным ядром nixpkgs.
  if [ "$HOST" != "nixos" ] || [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    break
  fi

  warn "сборка не удалась. Вероятная причина: nvidia legacy_580 не собирается"
  warn "против ядра CachyOS (или ядро x86_64-v3 не тянет это железо)."
  printf 'Собрать с обычным ядром nixpkgs (host nixos-stable-kernel)? [Y/n] '
  read -r k
  case "$k" in
    n|N) break ;;
    *)   HOST=nixos-stable-kernel ;;
  esac
done

if [ "$build_ok" -ne 1 ]; then
  cat >&2 <<EOF

${C_RED}[x]${C_OFF} сборка упала. Система НЕ изменена.
    бэкап: $backup
    что смотреть:
      - ошибка про nvidia/legacy_580 -> sudo ./scripts/install.sh --host nixos-stable-kernel
      - ошибка про имя host          -> sudo ./scripts/install.sh --host nixos
      - ошибка про hardware-configuration.nix -> убедись, что он лежит в $FLAKE_DIR
    полный лог сборки выше; после правок запусти скрипт снова.
EOF
  exit 1
fi

if [ "$BUILD_ONLY" -eq 1 ]; then
  log "готово (--build-only): собранное поколение -> $FLAKE_DIR/result"
  exit 0
fi

log "переключаю систему (switch)"
nixos-rebuild switch --flake "$FLAKE_DIR#$HOST" "${NIX_CACHE_ARGS[@]}"

# --- пост-проверки -----------------------------------------------------------
echo
if [ -x /run/current-system/sw/bin/ryoku ]; then
  log "ryoku CLI на месте"
else
  warn "ryoku CLI не найден в /run/current-system/sw/bin — проверь programs.ryoku.enable"
fi

if [ -d /run/current-system/share/wayland-sessions ]; then
  log "Wayland-сессии:"
  ls -1 /run/current-system/share/wayland-sessions | sed 's/^/      /'
fi

if systemctl is-enabled display-manager >/dev/null 2>&1; then
  log "display-manager включён (ly)"
else
  warn "display-manager не включён — проверь services.displayManager.ly.enable"
fi

# NVIDIA legacy_580: проверяем, что драйвер попал в новое поколение.
# После смены ядра nvidia-smi может не ответить до перезагрузки — это нормально.
if [ -x /run/current-system/sw/bin/nvidia-smi ]; then
  gpu_info="$(timeout 10 /run/current-system/sw/bin/nvidia-smi \
    --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || true)"
  if [ -n "$gpu_info" ]; then
    log "NVIDIA: $gpu_info"
  else
    warn "nvidia-smi есть, но GPU пока не отвечает — проверь после перезагрузки:"
    warn "  nvidia-smi"
    warn "  journalctl -k -b | grep -i nvidia"
  fi
else
  warn "nvidia-smi не найден — проверь hardware.nvidia.package (legacy_580)"
fi

user_password_ok=0
if id "$TARGET_USER" >/dev/null 2>&1; then
  case "$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}')" in
    P) user_password_ok=1 ;;
  esac
fi

if [ "$SKIP_PASSWORDS" -eq 0 ]; then
  if [ -t 0 ] && id "$TARGET_USER" >/dev/null 2>&1; then
    echo
    if [ "$user_password_ok" -eq 1 ]; then
      printf 'Пароль у %s уже задан. Сменить? [y/N] ' "$TARGET_USER"
      read -r a
      case "$a" in y|Y) if passwd "$TARGET_USER"; then user_password_ok=1; fi ;; esac
    else
      printf 'Задать пароль для %s (без пароля ly не пустит в систему)? [Y/n] ' "$TARGET_USER"
      read -r a
      case "$a" in
        n|N) ;;
        *)   if passwd "$TARGET_USER"; then user_password_ok=1; fi ;;
      esac
    fi

    printf 'Задать/сменить пароль root? [y/N] '
    read -r b
    case "$b" in y|Y) passwd root || warn "пароль root не изменён" ;; esac
  else
    warn "нет интерактивного терминала — пароли не запрашивались"
  fi
fi

if id "$TARGET_USER" >/dev/null 2>&1 && [ "$user_password_ok" -ne 1 ]; then
  warn "у '$TARGET_USER' нет пароля (или он заблокирован) — ly не даст войти."
  warn "  задай вручную: sudo passwd $TARGET_USER"
fi

cat <<EOF

${C_BLUE}Готово.${C_OFF}
  логин:        ly, сессия — ryoku-hyprland
  ядро:         $( [ "$HOST" = "nixos" ] && echo "CachyOS BORE x86_64-v3" || echo "обычное ядро nixpkgs (fallback)" )
  GPU:          NVIDIA legacy_580 (Pascal / GTX 1050), Wayland-переменные включены
  загрузчик:    systemd-boot, меню 3 с, 15 поколений для отката
  откат:        sudo nixos-rebuild switch --rollback
  обновление:   $( [ "$HOST" = "nixos" ] && echo "ryoku update   (или nixos-rebuild switch --flake $FLAKE_DIR#nixos)" || echo "sudo nixos-rebuild switch --flake $FLAKE_DIR#$HOST" )
$( [ "$HOST" = "nixos" ] || echo "  ! ryoku update из Hub собирает host nixos (CachyOS-ядро) — на fallback его не используй" )
  бэкап старого конфига: $backup

После перезагрузки выбирай в ly сессию Hyprland — это Ryoku.
Если после входа что-то не так:
  ryoku doctor
  journalctl -b -u display-manager
EOF
