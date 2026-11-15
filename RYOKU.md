# Ryoku-версия конфига — что изменено и как ставить

Копия `Minish777/nixos-idk`, подготовленная под **Ryoku on NixOS**
(https://github.com/Ryoku-dev/Ryoku-on-NixOS). Всё, что относится к десктопу,
отдано Ryoku; всё, что относится к железу, ядру, приложениям и пользователю,
осталось твоим.

- десктоп: Ryoku (Hyprland / niri / MangoWM) + **ly** как логин-менеджер;
- GPU: NVIDIA `legacy_580` (последняя ветка для Pascal / GTX 1050) + Wayland;
- ядро: CachyOS BORE `x86_64-v3` с бинарным кэшем.

## Что вырезано и почему

| Файл | Почему |
|---|---|
| `modules/environment/hyprland.nix` | `programs.hyprland`, `xdg.portal` и `hyprland-session.target` теперь принадлежат Ryoku. Он **жёстко** (`mkForce`) ставит свой Hyprland и свой `xdg-desktop-portal-hyprland`, потому что плагины ABI-зависимы. Второй, хостовый, портал рядом с ним — источник «портал не работает». |
| `modules/environment/noctalia.nix` | Noctalia — это Quickshell-оболочка, прямой конкурент Ryoku shell (бар, лаунчер, виджеты). Две оболочки на одном Hyprland = два бара и драка за сокеты. |
| `modules/environment/minimal/` | Отдельный dwl + waybar + mako + awww + swaylock. Третья параллельная сессия, третий набор баров/обоев. |

Сохранено из вырезанного: NVIDIA-переменные для Wayland →
`modules/hardware/nvidia-wayland.nix`. `hardware.bluetooth`,
`power-profiles-daemon`, `upower` Ryoku включает сам, дублировать не нужно.

## Что добавлено

- `flake.nix`: input `ryoku` + `ryoku.nixosModules.default`; два host'а —
  `nixos` (ядро CachyOS) и `nixos-stable-kernel` (обычное ядро nixpkgs).
- `modules/ryoku.nix`: `programs.ryoku` — `defaultCompositor = "hyprland"`,
  `browser = null` (берёт твой firefox из PATH, второй не ставит),
  `shell = "fish"`, `updateFlake = "/etc/nixos"`.
- `scripts/install.sh`: установка одной командой (см. ниже).
- `modules/hardware/nvidia-wayland.nix`: NVIDIA + Wayland env.
- `modules/hardware/kernel-cachy.nix` / `kernel-stable.nix`: ядро вынесено из
  `configuration.nix`, чтобы варианты не конфликтовали. Раньше это был один
  `kernel.nix`.

## Исправленные проблемы исходного конфига

1. **`path:/etc/nixos/flakes/...`** — абсолютный путь, флейк собирался только
   из ровно этого каталога. Стало `path:./flakes/...`.
2. **Нет пароля ни у `root`, ни у `steelium`** — на свежей установке войти
   некуда. `install.sh` предлагает задать пароли в конце.
3. **Группа `keyring`** в `extraGroups` в NixOS не существует — молча
   игнорировалась. Заменена на `render` и `input`.
4. **`services.xserver.xkb`** без X-сервера на Wayland не применяется —
   раскладку задавать в Ryoku (Hub → Keyboard).
5. **`nix.gc --delete-older-than 3d`** — удаляло поколения почти сразу, то есть
   ровно тот откат, за которым идут в NixOS. Стало `14d`.
6. **HDD с играми по старому UUID** — закомментирован до `lsblk -f`.
7. **Устаревший кэш CachyOS** — было `attic.xuyh0120.win` + ключ `EeAUQ+...`,
   апстрим раздаёт с `cache.lantian.pub/lantian` и ключом `WVGO7vs...`.
   Кэш не попадал, ядро собиралось локально. Заменено на актуальные значения
   из `nixConfig` флейка.
8. **`hardware-configuration.nix`** — нормально, что его нет: генерируется при
   установке. `install.sh` его сохраняет, а если нет — создаёт сам.
9. **`secrets/tg-ws-proxy-secret`** — файл в git не лежит (`.gitignore`).
   Если его нет, система соберётся, но служба tg-ws-proxy не стартует;
   `install.sh` предупредит и покажет команду создания.

## Установка

Что нужно заранее:

- интернет на машине (первая сборка тянет nixpkgs, Ryoku и его закреплённый
  nixpkgs — это несколько GiB);
- UEFI-установка NixOS (конфиг использует systemd-boot);
- свободно хотя бы ~40 GiB в `/nix` (Ryoku + steam + wine занимают немало);
- эта папка на флешке или в `git clone`.

При установке NixOS:

- в графическом установщике **не выбирай GNOME/KDE** — десктоп даст Ryoku,
  лишняя среда только наставит конфликтующих сервисов;
- создай пользователя `steelium` (или потом запусти скрипт с `--user <имя>`);
- пароль, который задашь при установке, останется твоим паролем для ly.

1. Ставишь NixOS как обычно (UEFI, btrfs или ext4 — не важно).
2. Копируешь эту папку на машину (флешка/`git clone`) — например в `~/nixos-idk`.
3. Запускаешь:

```bash
cd ~/nixos-idk
sudo ./scripts/install.sh
# если папка на FAT-флешке и бит «исполняемый» потерялся:
# sudo bash scripts/install.sh
```

Скрипт сам: сделает бэкап `/etc/nixos`, скопирует конфиг, сохранит или
сгенерирует `hardware-configuration.nix`, вернёт `secrets/`, сбросит
`flake.lock`, соберёт поколение и **только после успешной сборки** переключится,
потом предложит задать пароли.

Если сборка с ядром CachyOS упадёт (см. риски ниже), скрипт предложит собрать
с обычным ядром nixpkgs — это отдельный host `nixos-stable-kernel` в том же
флейке, десктоп и драйверы те же.

Полезное:

```bash
sudo ./scripts/install.sh --dry-run      # показать план, ничего не менять
sudo ./scripts/install.sh --build-only   # собрать, но не переключать
sudo ./scripts/install.sh --host nixos-stable-kernel   # сразу с обычным ядром
sudo ./scripts/install.sh --repo https://github.com/<you>/<repo>.git
```

После перезагрузки в ly выбираешь сессию **Hyprland** — это Ryoku.

Обновления дальше:

```bash
ryoku update                 # двигает только input ryoku и собирает поколение
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

Откат: `sudo nixos-rebuild switch --rollback` или поколение в загрузчике.
Бэкапы старых конфигов: `/var/backups/nixos-bootstrap/<дата>`.

## Про `flake.lock`

Он удалён намеренно: inputs изменились (добавлен `ryoku`, пути стали
относительными), а старый lock всё равно невалиден. При первой сборке Nix
зафиксирует актуальные версии всех inputs — то есть получишь свежий Ryoku и
свежий nixpkgs, без ручного `nix flake update`.

## Самые вероятные места, где сломается

1. **`nvidia legacy_580` + ядро CachyOS (6.1x).** 580 — последняя ветка с
   Pascal, может не собраться против слишком нового ядра. Для этого в флейке
   есть второй host: `nixos-stable-kernel` (то же самое, но ядро из nixpkgs —
   подключается `modules/hardware/kernel-stable.nix` вместо `kernel-cachy.nix`).
   `install.sh` предложит его сам, если сборка упала; вручную:
   `sudo ./scripts/install.sh --host nixos-stable-kernel`.
2. **Смешение mesa.** Ryoku принудительно ставит свою mesa из закреплённого
   nixpkgs (`mkForce`), а твои `hardware.graphics.extraPackages`
   (`nvidia-vaapi-driver` и т.п.) — из хостового. Если сломается VA-API —
   причина здесь.
3. **CachyOS-ядро `x86_64-v3`** требует AVX2 — у Xeon E5-2680 v4 он есть, но на
   другой машине атрибут может не собраться. `install.sh` это проверяет и
   предупреждает.
4. **ly + Wayland-сессии.** ly в NixOS читает `share/wayland-sessions`, так что
   `ryoku-hyprland` / `ryoku-niri` / `ryoku-mango` появятся в меню сами. Если
   после логина чёрный экран — смотри `journalctl -b -u display-manager` и
   `~/.local/state/ryoku/`.

## Если нужно вернуть старый десктоп

Файлы не потеряны — они в истории git этого репозитория:

```bash
git checkout HEAD~1 -- modules/environment
```

и вернуть импорты в `configuration.nix` (плюс выключить `programs.ryoku`).
