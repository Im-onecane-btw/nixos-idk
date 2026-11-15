{ config, pkgs, ... }:

{
  imports = [
    # Системное железо. Появляется само после установки NixOS
    # (или его сгенерирует scripts/install.sh).
    ./hardware-configuration.nix

    # Твои кастомные модули
    ./modules/hardware/nvidia.nix
    ./modules/hardware/nvidia-wayland.nix
    ./modules/hardware/kernel.nix

    # Ryoku: сам включает Hyprland/niri/Mango, оболочку, порталы, PipeWire,
    # Bluetooth, keyring и user-сервисы. SDDM он включает только если не выбран
    # другой логин-менеджер — у нас ly, поэтому SDDM не появится.
    # Отдельные hyprland.nix / noctalia.nix / minimal (dwl) больше не нужны.
    ./modules/ryoku.nix

    ./modules/apps.nix
    ./modules/services.nix
    ./modules/fonts.nix
    ./modules/nix-ld.nix
    ./modules/useflags.nix
  ];

  # Загрузчик
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 15; # запас поколений для отката

  # Двойная загрузка с Windows (раскомментируй и проверь ESP, если нужен Windows
  # в меню systemd-boot; UUID раздела посмотри через `lsblk -f`):
  # boot.loader.systemd-boot.extraEntries = {
  #   "windows.conf" = ''
  #     title Windows
  #     efi /EFI/Microsoft/Boot/bootmgfw.efi
  #   '';
  # };

  networking.hostName = "nixos";

  # Часовой пояс и локаль
  time.timeZone = "Europe/Moscow";
  i18n.defaultLocale = "ru_RU.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ru_RU.UTF-8";
    LC_IDENTIFICATION = "ru_RU.UTF-8";
    LC_MEASUREMENT = "ru_RU.UTF-8";
    LC_MONETARY = "ru_RU.UTF-8";
    LC_NAME = "ru_RU.UTF-8";
    LC_NUMERIC = "ru_RU.UTF-8";
    LC_PAPER = "ru_RU.UTF-8";
    LC_TELEPHONE = "ru_RU.UTF-8";
    LC_TIME = "ru_RU.UTF-8";
  };

  # X11-раскладка. На Wayland (Hyprland) она НЕ применяется — раскладку задаёт
  # сам Ryoku: Hub → Keyboard, либо ~/.config/hypr/*.conf. Оставлено на случай,
  # если когда-нибудь включишь X-сервер или Xwayland-приложения.
  services.xserver.xkb = {
    layout = "us,ru";
    options = "grp:alt_shift_toggle";
  };

  # Логин-менеджер: ly (TUI, работает до графики, X-сервер ему не нужен).
  # Ryoku видит включённый ly и не навязывает свой SDDM. Сессии
  # ryoku-hyprland / ryoku-niri / ryoku-mango попадают в список ly сами
  # (через services.displayManager.sessionPackages).
  services.displayManager.ly.enable = true;

  # Нужен для автологина и как «сессия по умолчанию» для systemd.
  # В самом ly сессия всё равно выбирается стрелками — первой в списке
  # будет ryoku-hyprland.
  services.displayManager.defaultSession = "ryoku-hyprland";

  # gamemode
  programs.gamemode.enable = true;

  # Пользователь.
  # ВАЖНО: на свежей установке пароля нет ни у root, ни у steelium — задай его
  # при установке (`passwd`) или временно раскомментируй строку ниже и смени
  # пароль после первого входа:
  users.users."steelium" = {
    isNormalUser = true;
    description = "steelium";
    extraGroups = [ "networkmanager" "wheel" "video" "render" "audio" "input" ];
    shell = pkgs.fish;
    # initialPassword = "changeme";
  };

  # HDD с играми.
  # UUID остался от старой машины/разметки: если диск тот же — раскомментируй,
  # иначе `nofail` просто тихо не смонтирует его. Новый UUID: `lsblk -f`.
  # fileSystems."/home/steelium/Games" = {
  #   device = "/dev/disk/by-uuid/99508f19-4d8a-4875-877a-7e0cd0f59cdd";
  #   fsType = "ext4";
  #   options = [ "defaults" "nofail" ];
  # };

  # fish shell
  programs.fish.enable = true;

  # Разрешаем нераспространяемые пакеты (нужно для драйверов NVIDIA и т.д.)
  nixpkgs.config.allowUnfree = true;

  # Прошивки устройств + микрокод CPU (важно для стабильности)
  hardware.enableRedistributableFirmware = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  zramSwap.enable = true;

  # Автоматическая сборка мусора.
  # Было 3d — это удаляло старые поколения почти сразу и убивало откат
  # (`nixos-rebuild --rollback`), ради которого Ryoku и ставится.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Автоматическая оптимизация хранилища (дедупликация)
  nix.settings.auto-optimise-store = true;

  system.stateVersion = "26.05";
}
