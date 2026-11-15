{ pkgs, inputs, lib, useCachyKernel ? true, ... }:

let
  # Бинарный кэш автора репозитория CachyOS.
  # Было: attic.xuyh0120.win + ключ EeAUQ+... — это устаревшие адрес и ключ,
  # кэш просто не попадал. Актуальные значения из flake.nix апстрима (nixConfig).
  cachyCache = {
    substituters = [ "https://cache.lantian.pub/lantian" ];
    trusted-public-keys = [ "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ=" ];
  };
in
{
  # Подключаем оверлей репозитория CachyOS.
  # default = ядро собирается против твоего nixpkgs (nixpkgs.config применяется,
  # но кэш может не попасть). pinned = точная ревизия nixpkgs из флейка CachyOS:
  # бинарный кэш попадает почти всегда, но ядро живёт в своей вселенной пакетов.
  # Оставлен default, чтобы nvidia/steam/прочее оставались из одного nixpkgs.
  nixpkgs.overlays = lib.optional useCachyKernel inputs.cachyos.overlays.default;

  nix.settings = lib.mkIf useCachyKernel cachyCache;

  # Указываем конкретную версию ядра: BORE планировщик + оптимизация x86-64-v3.
  # Для конфигурации `nixos-stable-kernel` это определение выключено, и берётся
  # обычное ядро из nixpkgs.
  boot.kernelPackages =
    lib.mkIf useCachyKernel pkgs.cachyosKernels.linuxPackages-cachyos-bore-x86_64-v3;

  # Производительный губернатор
  powerManagement.cpuFreqGovernor = "performance";
}
