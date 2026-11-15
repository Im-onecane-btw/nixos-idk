{ pkgs, inputs, ... }:

# Ядро CachyOS: BORE-планировщик + сборка x86_64-v3.
# Подключается только у host `nixos`. Для host `nixos-stable-kernel`
# вместо этого файла импортируется kernel-stable.nix.
{
  # Подключаем оверлей репозитория CachyOS.
  # default = ядро собирается против твоего nixpkgs (nixpkgs.config применяется,
  # но кэш может не попасть). pinned = точная ревизия nixpkgs из флейка CachyOS:
  # бинарный кэш попадает почти всегда, но ядро живёт в своей вселенной пакетов.
  # Оставлен default, чтобы nvidia/steam/прочее оставались из одного nixpkgs.
  nixpkgs.overlays = [
    inputs.cachyos.overlays.default
  ];

  # Бинарный кэш автора репозитория CachyOS.
  # Было: attic.xuyh0120.win + ключ EeAUQ+... — это устаревшие адрес и ключ,
  # кэш просто не попадал. Актуальные значения из flake.nix апстрима (nixConfig).
  # NixOS добавляет cache.nixos.org через mkAfter, поэтому он не пропадёт.
  nix.settings.substituters = [ "https://cache.lantian.pub/lantian" ];
  nix.settings.trusted-public-keys = [ "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ=" ];

  # Конкретная версия ядра: BORE планировщик + оптимизация x86-64-v3
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-bore-x86_64-v3;

  # Производительный губернатор
  powerManagement.cpuFreqGovernor = "performance";
}
