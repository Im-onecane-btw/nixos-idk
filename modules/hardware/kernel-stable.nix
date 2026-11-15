{ ... }:

# Резервный вариант ядра: обычное ядро из nixpkgs.
# Используется host'ом `nixos-stable-kernel` — если CachyOS-ядро и NVIDIA
# legacy_580 (Pascal / GTX 1050) не собираются вместе.
# Всё остальное (драйверы, Ryoku, приложения) идентично host'у `nixos`.
{
  powerManagement.cpuFreqGovernor = "performance";
}
