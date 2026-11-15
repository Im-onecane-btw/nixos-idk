# NixOS + Ryoku (конфиг для установки «в один заход»)

Готовый flake-конфиг для моей машины: **NixOS (unstable) + Ryoku** на Wayland.

- **Железо:** Intel Xeon E5-2680 v4 (28 потоков, AVX2) · 32 GB RAM · NVIDIA GeForce GTX 1050 (Pascal)
- **Десктоп:** Ryoku (Hyprland / niri / MangoWM) + логин-менеджер **ly** (TUI)
- **Ядро:** CachyOS BORE `x86_64-v3` + бинарный кэш (есть fallback на обычное ядро nixpkgs)
- **GPU:** NVIDIA `legacy_580` (последняя ветка для Pascal) + Wayland-переменные
- **Пользователь:** `steelium`, shell `fish`, hostname `nixos`, конфиг живёт в `/etc/nixos`
- **Загрузчик:** systemd-boot (UEFI), меню 3 с, 15 поколений для отката

`install.sh` сам включает flakes, скачивает/раскладывает конфиг, создаёт секреты, собирает систему и переключается на неё. Подробности изменений и тонкости — в [`RYOKU.md`](RYOKU.md).

---

## Что понадобится

- Флешка с образом **NixOS (graphical ISO)**.
- Интернет (первая сборка тянет несколько GiB; ядро/Ryotunes берутся из бинарных кэшей).
- **UEFI**-загрузка (не Legacy/CSM). Конфиг ставит **systemd-boot** — в BIOS-режиме он не установится.
- Свободно **≥ 40 GiB** под `/nix` (Ryoku + Steam + Wine занимают место).
- Этот репозиторий на GitHub: `https://github.com/Im-onecane-btw/nixos-idk` (или архив `nixos-idk-ryoku.zip` на флешке).

---

## Пошаговая установка

### Шаг 1. Установить NixOS графическим установщиком

1. Загрузись с установочной флешки в режиме **UEFI** (в BIOS/Setup выключи CSM/Legacy, если был включён).
2. Запусти графический установщик (Calamares) и пройди разметку/язык/часовой пояс как обычно.
3. Важные выборы в установщике:
   - **Окружение рабочего стола:** **не выбирай GNOME/KDE/Xfce** — рабочий стол даст Ryoku. Оставь «No Desktop»/минимальную установку, если есть такой вариант.
   - **Пользователь:** создай пользователя **`steelium`** (имя важно: под него заточен конфиг; можно и другое, но тогда в шаге 3 передай `--user <имя>` и поправь `configuration.nix`).
   - **Пароль:** задай пароль — он останется паролем для входа в `ly`. (Если забудешь/не задашь, скрипт предложит задать его в конце.)
   - **Разметка:** любая подходящая (btrfs/ext4). Убедись, что под `/nix` (или корень, если `/nix` не отдельный раздел) есть ~40 GiB+. Нужен EFI-раздел, смонтированный в `/boot`.
   - **Сеть:** подключи интернет (Wi-Fi/Ethernet) — без него первая сборка не пройдёт.
4. Дождись окончания установки и перезагрузись в установленную систему (флешку можно вынуть).

### Шаг 2. Подготовка после первой загрузки

1. Войди в установленную систему (в консоль/минимальную сессию — как даст установщик без DE).
2. Убедись, что есть интернет: `ping -c1 1.1.1.1` или `ping -c1 nixos.org`.
3. (Рекомендуется) открой терминал, где удобно вводить команды.

### Шаг 3. Запустить установку конфига (одна команда)

**Вариант A — одной командой, ничего не скачивая заранее (нужен интернет и актуальный репозиторий на GitHub):**

```bash
curl -fsSL https://raw.githubusercontent.com/Im-onecane-btw/nixos-idk/main/scripts/bootstrap.sh | sudo bash
```

`bootstrap.sh` скачает репозиторий, запустит `install.sh`, а тот сделает всё остальное.

**Вариант B — если конфиг уже склонирован или распакован (например, zip с флешки):**

```bash
cd ~/nixos-idk   # путь к папке с flake.nix / scripts/install.sh
sudo bash scripts/install.sh
```

> Если рядом со скриптом нет `flake.nix`, `install.sh` сам попробует скачать конфиг из `https://github.com/Im-onecane-btw/nixos-idk.git`.
>
> Если видишь ошибку `$'\r': command not found` (файлы залиты с Windows-переводами строк), выполни `sed -i 's/\r$//' scripts/install.sh` и запусти снова. В `nixos-idk-ryoku.zip` файлы уже с правильными окончаниями строк (LF).

### Шаг 4. Что сделает скрипт и что от тебя потребуется

`install.sh` выполняет по порядку:

1. Включает `nix-command` и `flakes` в `/etc/nix/nix.conf` (на свежей NixOS они выключены) и проверяет это.
2. Проверяет окружение (NixOS, UEFI, место на диске, AVX2) и берёт конфиг (локально / `--repo` / официальный репозиторий).
3. Делает бэкап текущего `/etc/nixos` в `/var/backups/nixos-bootstrap/<дата>`.
4. Копирует конфиг в `/etc/nixos`, сохраняет/генерирует `hardware-configuration.nix`.
5. Создаёт `secrets/tg-ws-proxy-secret`, если его нет.
6. **Собирает** поколение (`nixos-rebuild build`) с кэшами CachyOS и Ryoku — система ещё не меняется.
7. **Только после успешной сборки** переключается (`nixos-rebuild switch`).
8. Проверяет Ryoku, Wayland-сессии, ly, NVIDIA, flakes/trusted-users, подключает flathub, кладёт копию конфига в `~/nixos-idk`.

Во время работы скрипт может спросить:

- **Подтверждение продолжения** — отвечай `y`.
- **Пароль пользователя `steelium`** (и опционально root) — задай, без пароля `ly` не пустит в систему.
- **Если сборка с ядром CachyOS упала** (часто из‑за NVIDIA `legacy_580` на слишком новом ядре) — согласись собрать с обычным ядром (`nixos-stable-kernel`). Десктоп и драйверы те же.

> Первая сборка долгая: скачиваются nixpkgs/Ryoku и пакеты из кэшей. Это нормально.

Полезные флаги:

```bash
sudo bash scripts/install.sh --dry-run                  # показать план, ничего не менять
sudo bash scripts/install.sh --build-only               # только собрать (без switch)
sudo bash scripts/install.sh --host nixos-stable-kernel # сразу с обычным ядром
sudo bash scripts/install.sh --reset-lock               # заново зафиксировать inputs
sudo bash scripts/install.sh --user <имя>               # другое имя пользователя
sudo bash scripts/install.sh --repo <URL>               # взять конфиг из другого репозитория
```

### Шаг 5. Перезагрузка и первый вход

1. Перезагрузись: `reboot`.
2. В загрузчике **systemd-boot** подожди 3 с (или выбери нужное поколение — их хранится 15).
3. На экране **ly** войди под `steelium` и выбери сессию **Hyprland** — это Ryoku (`ryoku-hyprland`). Сессии `ryoku-niri` и `ryoku-mango` тоже доступны.

### Шаг 6. Проверка после установки

```bash
nvidia-smi                         # видеокарта и версия драйвера (после первого входа/перезагрузки)
journalctl -k -b | grep -i nvidia  # логи драйвера, если что-то не так
ryoku doctor                       # диагностика Ryoku
journalctl -b -u display-manager   # логи ly
nix config show experimental-features  # должны быть nix-command flakes
```

> `nvidia-smi` может не ответить сразу после `switch` до перезагрузки на новое ядро — это нормально, проверь после ребута.

---

## Обновление и откат

```bash
ryoku update                 # обновить только input Ryoku и пересобрать (host nixos)
sudo nixos-rebuild switch --flake /etc/nixos#nixos
# на fallback-ядре:
# sudo nixos-rebuild switch --flake /etc/nixos#nixos-stable-kernel
```

- **Откат:** `sudo nixos-rebuild switch --rollback` или выбрать предыдущее поколение в меню systemd-boot.
- **Бэкапы старых `/etc/nixos`:** `/var/backups/nixos-bootstrap/<дата>`.
- `flake.lock` при повторных запусках `install.sh` сохраняется; обновить inputs принудительно — `sudo bash scripts/install.sh --reset-lock`.
- **`ryoku update` из Hub** собирает host `nixos` (CachyOS). Если ты на `nixos-stable-kernel`, не используй его — обновляй через `nixos-rebuild switch --flake /etc/nixos#nixos-stable-kernel`.

---

## Если что-то пошло не так

| Симптом | Что делать |
|---|---|
| Установщик/система в BIOS/CSM, systemd-boot не ставится | Нужна установка в **UEFI**: выключи CSM в BIOS и переустанови/загрузи в UEFI-режиме |
| `$'\r': command not found` при запуске скрипта | `sed -i 's/\r$//' scripts/install.sh` и запустить снова (или используй zip с LF) |
| Сборка падает на `nvidia`/`legacy_580` | `sudo bash scripts/install.sh --host nixos-stable-kernel` (или согласиться на fallback при вопросе скрипта) |
| CPU без AVX2 | Используй `--host nixos-stable-kernel` (CachyOS-вариант собран под x86_64-v3) |
| `ly` не пускает (нет пароля) | Зайди с другого tty/root и выполни `sudo passwd steelium` |
| Мало места на `/nix` | Нужно ≥ ~40 GiB свободно; почисти или расширь раздел |
| `nixos-rebuild --flake` / `nix flake` ругается на experimental features | Скрипт включает их сам; вручную: добавить `experimental-features = nix-command flakes` в `/etc/nix/nix.conf` и в `configuration.nix` (`nix.settings.experimental-features`) |
| Нет интернета при установке | Нужен доступ к `cache.nixos.org`, `cache.lantian.pub`, `ryotunes.cachix.org` и GitHub |

Конфиг не меняет систему до успешного `build` — при ошибке сборки текущее поколение остаётся рабочим, а старый `/etc/nixos` лежит в бэкапе.

---

## Структура

- `flake.nix` — inputs (nixpkgs, ryoku, cachyos, …) и хосты `nixos` / `nixos-stable-kernel`
- `configuration.nix` — базовая система, пользователь, загрузчик, локаль, gc, flakes/trusted-users
- `modules/` — железо, NVIDIA/Wayland, ядра, приложения, сервисы, Ryoku
- `scripts/install.sh` — основной установщик
- `scripts/bootstrap.sh` — загрузчик для установки одной командой (`curl | sudo bash`)
- `RYOKU.md` — что изменено относительно исходного конфига и подробные заметки
