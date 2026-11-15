# Ryoku-версия конфига — что изменено и как ставить

Это копия `Minish777/nixos-idk`, подготовленная под **Ryoku on NixOS**
(https://github.com/Ryoku-dev/Ryoku-on-NixOS). Логика простая: всё, что
относится к десктопу, отдаётся Ryoku; всё, что относится к железу, ядру,
приложениям и пользователю, остаётся твоим.

## Что вырезано и почему

| Файл | Почему |
|---|---|
| `modules/environment/hyprland.nix` | `programs.hyprland`, `xdg.portal` и `hyprland-session.target` теперь принадлежат Ryoku. Он **жёстко** (`mkForce`) ставит свой Hyprland и свой `xdg-desktop-portal-hyprland`, потому что плагины ABI-зависимы. Второй, хостовый, портал рядом с ним — источник «портал не работает». |
| `modules/environment/noctalia.nix` | Noctalia — это Quickshell-оболочка, то есть прямой конкурент Ryoku shell (бар, лаунчер, виджеты). Две оболочки на одном Hyprland = два бара и драка за сокеты. |
| `modules/environment/minimal/` | Отдельный dwl + waybar + mako + awww + swaylock. Третья параллельная сессия, третий набор баров/обоев. Для теста Ryoku это шум. |

Что из вырезанного **сохранено**, потому что нужно:

- NVIDIA-переменные для Wayland → новый `modules/hardware/nvidia-wayland.nix`
  (`LIBVA_DRIVER_NAME`, `GBM_BACKEND`, `__GLX_VENDOR_LIBRARY_NAME`,
  `NIXOS_OZONE_WL`).
- `hardware.bluetooth`, `power-profiles-daemon`, `upower` — их Ryoku включает
  сам, дублировать не нужно.

## Что добавлено

- `flake.nix`: input `ryoku` + `ryoku.nixosModules.default` в модулях.
- `modules/ryoku.nix`: `programs.ryoku` — `defaultCompositor = "hyprland"`,
  `browser = null` (берёт твой firefox из PATH, второй не ставит),
  `shell = "fish"`, `updateFlake = "/etc/nixos"`.
- `modules/hardware/nvidia-wayland.nix`: см. выше.
- `configuration.nix`: `boot.loader.systemd-boot.configurationLimit = 15`,
  закомментированный HDD с играми, комментарий про пароль root/пользователя,
  `nix.gc` с `--delete-older-than 14d` вместо `3d`.

## Исправленные проблемы исходного конфига

1. **Нет `hardware-configuration.nix`** — флейк в таком виде не соберётся
   вообще (`path does not exist`). Файла нет в репозитории, его надо
   сгенерировать на новой машине.
2. **`path:/etc/nixos/flakes/...`** — абсолютный путь. Флейк работал только
   если репозиторий лежит ровно в `/etc/nixos`. Заменено на `path:./flakes/...`.
3. **Нет пароля ни у `root`, ни у `steelium`** — на свежей установке войти
   некуда, включая SDDM. Задать при установке (`passwd`) или через
   `initialPassword`.
4. **Группа `keyring`** в `extraGroups` в NixOS не существует — молча
   игнорировалась. Заменена на `render` и `input` (реально нужны для GPU/HID).
5. **`services.xserver.xkb`** без `services.xserver.enable` — на Wayland не
   применяется. Раскладку задавать в Ryoku (Hub → Keyboard).
6. **`nix.gc --delete-older-than 3d`** — удалял поколения почти сразу, то есть
   ровно тот откат, за которым идут в NixOS. Стало `14d`.
7. **HDD с играми по старому UUID** — `nofail` спасал загрузку, но монтирование
   молча не работало. Закомментировано до проверки `lsblk -f`.
8. **Устаревший бинарный кэш CachyOS** — в конфиге был
   `attic.xuyh0120.win` и ключ `EeAUQ+...`, а апстрим уже раздаёт с
   `cache.lantian.pub/lantian` с ключом `WVGO7vs...`. Кэш не попадал, ядро
   собиралось локально. Заменено на актуальные значения из `nixConfig` флейка.

## Чего я НЕ проверял

На этой машине (Windows) нет `nix`, поэтому **eval/сборка не проверялись**.
Статически проверено: имена опций (`programs.throne.tunMode.setuid`,
`programs.appimage.package`, `programs.obs-studio` + `cudaSupport`,
`programs.dwl.extraSessionCommands`, `nvidiaPackages.legacy_580`,
`nix.settings.substituters` не выкидывает `cache.nixos.org` — NixOS добавляет
его через `mkAfter`) и совместимость с модулем Ryoku (`mkDefault`/`mkForce`
там, где это важно).

## Установка

```bash
# 0. Репозиторий — в /etc/nixos (или поменяй updateFlake в modules/ryoku.nix)
sudo cp -r nixos-idk-ryoku /etc/nixos

# 1. Железо: единственный файл, который нельзя скопировать с другой машины
sudo nixos-generate-config --show-hardware-config | sudo tee /etc/nixos/hardware-configuration.nix

# 2. Lock создаётся заново: inputs изменились (добавлен ryoku, пути стали
#    относительными), старый flake.lock всё равно невалиден.
sudo rm -f /etc/nixos/flake.lock

# 3. Собрать БЕЗ переключения — если что-то не так, система не тронется
sudo nixos-rebuild build --flake /etc/nixos#nixos

# 4. Переключиться
sudo nixos-rebuild switch --flake /etc/nixos#nixos

# 5. Перезагрузка. В SDDM выбрать сессию «Hyprland» (это Ryoku).
```

Обновления дальше:

```bash
ryoku update                 # двигает только input ryoku и собирает поколение
sudo nixos-rebuild switch --flake /etc/nixos#nixos   # обычный путь
```

Откат: `sudo nixos-rebuild switch --rollback` или выбрать поколение в
загрузчике.

## Самые вероятные места, где сломается

1. **`nvidia legacy_580` + ядро CachyOS (6.1x).** 580 — последняя ветка с
   Pascal (GTX 1050), и она может не собраться против слишком нового ядра.
   Проверка: временно убрать `boot.kernelPackages` из `modules/hardware/kernel.nix`
   (ядро из nixpkgs). Если собралось — виновато ядро, а не драйвер.
2. **SDDM в Wayland на NVIDIA.** Если получишь пустой экран вместо логина —
   верни `services.displayManager.ly.enable = true` в `configuration.nix`;
   Ryoku это поддерживает и SDDM тогда не включает.
3. **Смешение mesa.** Ryoku принудительно ставит свою mesa из закреплённого
   nixpkgs (`mkForce`), а твои `hardware.graphics.extraPackages`
   (`nvidia-vaapi-driver` и т.п.) — из хостового. Если сломается VA-API —
   причина здесь.
4. **CachyOS-ядро `x86_64-v3`** требует AVX2 — у Xeon E5-2680 v4 он есть, но на
   другой машине атрибут может не собраться.

## Если нужно вернуть старый десктоп

Файлы не потеряны — они в истории git этого репозитория:

```bash
git checkout HEAD~1 -- modules/environment
```

и вернуть импорты в `configuration.nix` (плюс убрать `programs.ryoku.enable`
или оставить его выключенным).
