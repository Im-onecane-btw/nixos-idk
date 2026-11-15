#!/usr/bin/env bash
# =============================================================================
#  install.sh — разворачивает этот флейк на уже установленном NixOS.
#
#  Сценарий: поставил NixOS графическим установщиком (UEFI, пользователь
#  steelium, без GNOME/KDE) -> загрузился -> запустил одну команду.
#  Скрипт сам включит flakes, при необходимости скачает репозиторий, разложит
#  файлы в /etc/nixos, создаст секреты, соберёт и переключит систему с Ryoku,
#  NVIDIA legacy_580 и ядром CachyOS.
#
#  Что делает:
#    1. включает experimental-features (nix-command, flakes) в /etc/nix/nix.conf
#       — на свежей NixOS флейки выключены, без этого шага ничего не соберётся
#    2. проверяет, что это NixOS в UEFI и что хватает места
#    3. находит конфиг: папка рядом со скриптом -> --repo -> официальный репозиторий
#       (git есть — клонирует им; нет — через nix run; нет сети для git — curl)
#    4. делает бэкап текущего /etc/nixos в /var/backups/nixos-bootstrap/<дата>
#    5. копирует конфиг в /etc/nixos
#    6. сохраняет/генерирует hardware-configuration.nix
#    7. создаёт secrets/tg-ws-proxy-secret, если его нет
#    8. собирает поколение (build), и только потом переключается (switch)
#       если сборка с ядром CachyOS упала — предложит собрать с обычным ядром
#    9. проверяет Ryoku, Wayland-сессии, NVIDIA, flakes, trusted-users, flathub
#   10. копирует конфиг в ~<user>/nixos-idk и предлагает задать пароли
#
#  Использование:
#    sudo bash scripts/install.sh
#    curl -fsSL https://raw.githubusercontent.com/Im-onecane-btw/nixos-idk/main/scripts/bootstrap.sh | sudo bash
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
# Откуда брать конфиг, если рядом со скриптом нет flake.nix и не указан --repo.
DEFAULT_REPO=https://github.com/Im-onecane-btw/nixos-idk.git
REPO_URL=""
BRANCH=""
DRY_RUN=0
ASSUME_YES=0
BUILD_ONLY=0
SKIP_PASSWORDS=0
RESET_LOCK=0
# Скрипт запущен через `curl ... | sudo bash` — у него нет flake.nix рядом,
# тогда он скачает репозиторий сам, но не сможет до него дочитать (exit 0 у
# pipe). Поэтому в конце дёргает install.sh из /etc/nixos.
PIPED_BOOTSTRAP=0

# Если скрипт запущен стримом (`curl ... | sudo bash`), stdin — pipe. Вопросы
# всё равно можно задать через /dev/tty (если есть терминал), поэтому --yes
# не форсируем; флаг нужен только чтобы понимать контекст в конце.
if [ ! -t 0 ]; then
  PIPED_BOOTSTRAP=1
fi

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

SELF="${BASH_SOURCE[0]-$0}"
if [ -r "$SELF" ] && [ "$SELF" != "/dev/stdin" ] && [ "${SELF#/dev/fd/}" = "$SELF" ]; then
  SELF_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd)"
  LOCAL_ROOT="$(cd -- "$SELF_DIR/.." && pwd)"
else
  # Скрипт пришёл из pipe/process substitution — рядом с ним ничего нет.
  SELF_DIR=""
  LOCAL_ROOT=""
fi

ask() {
  # Читает ответ в $REPLY. В неинтерактивном режиме возвращает 1 (по умолчанию «нет»).
  # При piped-запуске, но с доступным /dev/tty, всё равно спрашиваем у человека.
  local prompt="$1"
  if [ -t 0 ]; then
    printf '%s' "$prompt"
    IFS= read -r REPLY || return 1
    return 0
  elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r REPLY < /dev/tty || return 1
    return 0
  else
    REPLY=""
    return 1
  fi
}

# --- root --------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 \
    || die "нужен root, а sudo не найден — запусти скрипт из-под root"
  log "нужен root, перезапускаю через sudo"
  exec sudo -- bash "$SELF_DIR/$(basename -- "$SELF")" "${ORIG_ARGS[@]}"
fi

# --- flakes ------------------------------------------------------------------
# На свежей NixOS experimental-features пустой: `nixos-rebuild --flake` и любой
# `nix` командой без флага просто падают. Включаем flake-режим до всех вызовов
# nix и оставляем его в системе (NixOS позже перезапишет nix.conf из
# nix.settings.experimental-features в configuration.nix — там он уже есть).
export NIX_CONFIG="experimental-features = nix-command flakes"
export NIXPKGS_ALLOW_UNFREE=1

if ! command -v nix >/dev/null 2>&1; then
  echo "[x] nix не найден в PATH — это не установленный NixOS или PATH не загружен" >&2
  exit 1
fi

enable_flakes() {
  mkdir -p /etc/nix
  if [ -L /etc/nix/nix.conf ]; then
    # /etc/nix/nix.conf — симлинк в /etc/static; дописывать в него нельзя,
    # делаем обычный файл с тем же содержимым.
    cp --remove-destination "$(readlink -f /etc/nix/nix.conf)" /etc/nix/nix.conf
  elif [ ! -e /etc/nix/nix.conf ]; then
    : > /etc/nix/nix.conf
  fi

  local have_flakes=0
  if grep -qsE '^[[:space:]]*experimental-features[[:space:]]*=' /etc/nix/nix.conf &&
     grep -qsE '^[[:space:]]*experimental-features[[:space:]]*=.*\bflakes\b' /etc/nix/nix.conf &&
     grep -qsE '^[[:space:]]*experimental-features[[:space:]]*=.*\bnix-command\b' /etc/nix/nix.conf; then
    have_flakes=1
  fi

  if [ "$have_flakes" -eq 0 ]; then
    # Nix читает ключи по порядку и последнее значение выигрывает, поэтому
    # дописывание в конец безопасно.
    printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf
    log "включил flakes в /etc/nix/nix.conf"
  else
    log "flakes уже включены в /etc/nix/nix.conf"
  fi

  nix config show experimental-features 2>/dev/null | grep -qw flakes \
    && log "проверка: nix видит flake-режим" \
    || warn "nix не подтвердил flake-режим — проверь /etc/nix/nix.conf"
}

enable_flakes

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

# Клонирует репозиторий $1 в $2. Три способа подряд: на свежей NixOS может не
# быть git, а если git есть — он всё равно не поможет без сети.
#   git в PATH -> nix run nixpkgs#git -> curl + tar-архив ветки
clone_repo() {
  local url="$1" dest="$2" tarball
  if command -v git >/dev/null 2>&1; then
    if [ -n "$BRANCH" ]; then
      git clone --depth 1 --branch "$BRANCH" "$url" "$dest" && return 0
    else
      git clone --depth 1 "$url" "$dest" && return 0
    fi
    warn "git clone не удался — пробую другой способ"
  else
    log "git не установлен — тяну его разово через nix run"
    if [ -n "$BRANCH" ]; then
      nix run nixpkgs#git -- clone --depth 1 --branch "$BRANCH" "$url" "$dest" && return 0
    else
      nix run nixpkgs#git -- clone --depth 1 "$url" "$dest" && return 0
    fi
    warn "nix run git не сработал — пробую скачать архив"
  fi

  # Последний вариант: tar-архив ветки. curl входит в corePackages NixOS,
  # то есть есть всегда, даже без git и без flake-режима.
  command -v curl >/dev/null 2>&1 || return 1
  tarball="${url%.git}/archive/refs/heads/${BRANCH:-main}.tar.gz"
  mkdir -p "$dest"
  curl -fsSL "$tarball" | tar -xz -C "$dest" --strip-components=1
}

TMP_DIR="$(mktemp -d)"

# Если скрипт запущен стримом (`curl ... | sudo bash`), его собственная папка —
# это /dev/fd/63, а flake-файлов рядом нет. Тогда доверяем уже скачанному
# конфигу в TMP_DIR и не лезем в BASH_SOURCE.
if [ -n "$REPO_URL" ]; then
  log "клонирую $REPO_URL"
  clone_repo "$REPO_URL" "$TMP_DIR/src" \
    || die "не удалось получить конфиг из $REPO_URL"
  SRC="$TMP_DIR/src"
elif [ "$PIPED_BOOTSTRAP" -eq 1 ] || [ ! -f "$LOCAL_ROOT/flake.nix" ]; then
  warn "рядом со скриптом нет flake.nix — беру официальный репозиторий"
  log "клонирую $DEFAULT_REPO"
  clone_repo "$DEFAULT_REPO" "$TMP_DIR/src" \
    || die "не удалось скачать $DEFAULT_REPO — укажи --repo URL или положи конфиг рядом со скриптом"
  SRC="$TMP_DIR/src"
else
  SRC="$LOCAL_ROOT"
fi

[ -f "$SRC/configuration.nix" ] || die "в $SRC нет configuration.nix"

log "источник конфига: $SRC"
log "цель: $FLAKE_DIR  (host: $HOST)"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF

План (--dry-run, ничего не меняется):
  0. включить flakes в /etc/nix/nix.conf (сделано до этого вывода)
  1. бэкап $FLAKE_DIR -> $BACKUP_DIR/<дата>
  2. копирование $SRC -> $FLAKE_DIR (без .git)
  3. hardware-configuration.nix: сохранить существующий или сгенерировать
  4. secrets/tg-ws-proxy-secret: создать, если его нет
  5. flake.lock: $([ "$RESET_LOCK" -eq 1 ] && echo "удалить (--reset-lock)" || echo "сохранить (создастся при первой сборке)")
  6. nixos-rebuild build --flake $FLAKE_DIR#$HOST (с кэшами CachyOS + Ryoku)
$( [ "$BUILD_ONLY" -eq 1 ] && echo "  7. (--build-only: switch пропускается)" || echo "  7. nixos-rebuild switch --flake $FLAKE_DIR#$HOST" )
  8. при падении сборки — предложение собрать с обычным ядром (host nixos-stable-kernel)
  9. проверка ryoku, Wayland-сессий, NVIDIA, flakes, trusted-users, flathub
 10. клон конфига в ~$TARGET_USER/nixos-idk, пароли

EOF
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  if ask 'Продолжить? [y/N] '; then
    case "$REPLY" in y|Y|yes|YES) ;; *) die "отменено" ;; esac
  else
    # Нет ни tty, ни /dev/tty — неинтерактивный запуск: продолжаем.
    warn "нет терминала для подтверждения — продолжаю автоматически"
  fi
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
  if [ "$HOST" != "nixos" ]; then
    break
  fi

  if [ "$ASSUME_YES" -eq 1 ]; then
    warn "сборка с CachyOS упала — пробую nixos-stable-kernel"
    HOST=nixos-stable-kernel
    continue
  fi

  warn "сборка не удалась. Вероятная причина: nvidia legacy_580 не собирается"
  warn "против ядра CachyOS (или ядро x86_64-v3 не тянет это железо)."
  if ask 'Собрать с обычным ядром nixpkgs (host nixos-stable-kernel)? [Y/n] '; then
    case "$REPLY" in
      n|N) break ;;
      *)   HOST=nixos-stable-kernel ;;
    esac
  else
    warn "нет терминала — пробую nixos-stable-kernel автоматически"
    HOST=nixos-stable-kernel
  fi
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

# NixOS перезаписал /etc/nix/nix.conf из declarative-настроек: проверяем, что
# flakes и доверенные пользователи действительно попали в конфиг.
if grep -qsE '^[[:space:]]*experimental-features[[:space:]]*=.*flakes' /etc/nix/nix.conf; then
  log "flakes включены системно (/etc/nix/nix.conf)"
else
  # На случай, если конфиг не пересоздался (или пользователь его правил):
  # дописываем и просим пересобрать позже.
  printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf
  warn "flakes не были в /etc/nix/nix.conf — дописал, перезайди после перезагрузки"
fi
if nix config show trusted-users 2>/dev/null | grep -q '@wheel'; then
  log "wheel в trusted-users: nix работает без sudo"
else
  warn "wheel нет в nix.settings.trusted-users — nix будет просить sudo"
fi

# Flatpak: подключаем flathub, чтобы приложения ставились без ручных команд.
FLATPAK=/run/current-system/sw/bin/flatpak
if [ -x "$FLATPAK" ]; then
  if "$FLATPAK" remote-add --if-not-exists flathub \
       https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1; then
    log "flatpak: flathub подключён"
  else
    warn "flatpak: flathub не добавлен (нет сети? повтори: flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo)"
  fi
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

# --- пользователь: пароль, fish, группы --------------------------------------
# install.sh уже отработал switch, поэтому пользователь из configuration.nix
# существует. Если его нет (например, сменили --user или имя в конфиге) —
# заводим здесь, чтобы после перезагрузки было под кем войти в ly.
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  log "создаю пользователя $TARGET_USER"
  useradd -m -s /run/current-system/sw/bin/fish -G wheel,networkmanager,video,render,audio,input "$TARGET_USER" \
    || warn "не удалось создать $TARGET_USER — проверь users.users в configuration.nix"
fi

if [ "$SKIP_PASSWORDS" -eq 0 ] && id "$TARGET_USER" >/dev/null 2>&1; then
  can_ask=0
  if [ -t 0 ] || { [ -r /dev/tty ] && [ -w /dev/tty ]; }; then can_ask=1; fi
  if [ "$can_ask" -eq 1 ]; then
    echo
    if [ "$user_password_ok" -eq 1 ]; then
      if ask "Пароль у $TARGET_USER уже задан. Сменить? [y/N] "; then
        case "$REPLY" in y|Y) passwd "$TARGET_USER" && user_password_ok=1 || true ;; esac
      fi
    else
      if ask "Задать пароль для $TARGET_USER (без пароля ly не пустит в систему)? [Y/n] "; then
        case "$REPLY" in
          n|N) ;;
          *)   passwd "$TARGET_USER" && user_password_ok=1 || true ;;
        esac
      else
        passwd "$TARGET_USER" && user_password_ok=1 || warn "пароль $TARGET_USER не задан"
      fi
    fi

    if ask 'Задать/сменить пароль root? [y/N] '; then
      case "$REPLY" in y|Y) passwd root || warn "пароль root не изменён" ;; esac
    fi
  else
    warn "нет интерактивного терминала — пароли не запрашивались"
  fi
fi

# --- домашняя копия репозитория ----------------------------------------------
# /etc/nixos мы чистим при каждом запуске и убираем из него .git (иначе Nix
# соберёт только tracked-файлы и потеряет hardware-configuration.nix). Поэтому
# для Hub/ryoku update и ручной работы с git держим клон у пользователя.
if id "$TARGET_USER" >/dev/null 2>&1 && [ -d /home/"$TARGET_USER" ]; then
  HOME_COPY="/home/$TARGET_USER/nixos-idk"
  if [ ! -d "$HOME_COPY" ]; then
    log "копирую конфиг в $HOME_COPY"
    mkdir -p "$HOME_COPY"
    cp -a "$FLAKE_DIR"/. "$HOME_COPY"/
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_COPY"
  else
    log "копия репозитория уже есть: $HOME_COPY"
  fi
  # Официальный remote, чтобы потом можно было `git pull` (git нужен, но его
  # ставит сам конфиг; на первом запуске его ещё нет — тогда просто пропускаем).
  if [ -d "$HOME_COPY/.git" ] && command -v git >/dev/null 2>&1; then
    git -C "$HOME_COPY" remote set-url origin "$DEFAULT_REPO" 2>/dev/null \
      || git -C "$HOME_COPY" remote add origin "$DEFAULT_REPO" 2>/dev/null \
      || true
  fi
fi

# ryoku update и Hub ищут флейк в /etc/nixos — проверяем, что он там есть.
if [ ! -f "$FLAKE_DIR/flake.nix" ]; then
  warn "в $FLAKE_DIR нет flake.nix — ryoku update не найдёт конфиг"
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

# Если install.sh запустили прямо стримом (curl .../install.sh | sudo bash),
# терминала для вопросов всё равно нет: повторный запуск оттуда же бесполезен.
# Лучше использовать bootstrap.sh (он скачает репозиторий и запустит скрипт
# обычным процессом) либо выполнить установку в интерактивной оболочке.
if [ "$PIPED_BOOTSTRAP" -eq 1 ]; then
  warn "установка шла без терминала (stdin — pipe). Пароли и интерактивные шаги пропущены."
  warn "рекомендуется запустить: sudo bash $FLAKE_DIR/scripts/install.sh"
fi
