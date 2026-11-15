{
  description = "Steelium NixOS Flake Configuration";

  inputs = {
    # Актуальный нестабильный канал NixOS
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Ryoku on NixOS — официальный декларативный порт десктопа Ryoku
    # (Hyprland + niri + MangoWM, оболочка Quickshell, Hub, Ryostore).
    ryoku.url = "github:Ryoku-dev/Ryoku-on-NixOS";

    # tg-ws-proxy
    # Относительный путь, а не path:/etc/nixos/... — флейк больше не привязан
    # к одному каталогу и собирается из любого места.
    tg-ws-proxy.url = "path:./flakes/tg-ws-proxy";

    # Репозиторий ядра CachyOS
    cachyos = {
      url = "github:xddxdd/nix-cachyos-kernel";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # millennium
    millennium.url = "github:SteamClientHomebrew/Millennium?dir=packages/nix";

    # spicetify
    spicetify-nix.url = "github:Gerg-L/spicetify-nix";

    # lyricspot
    lyricspot.url = "path:./flakes/lyricspot";

    # Zen Browser флок
    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ryoku, spicetify-nix, tg-ws-proxy, lyricspot, ... }@inputs:
    let
      # Одна и та же система, два варианта ядра:
      #   useCachyKernel = true  -> CachyOS BORE x86_64-v3 + его бинарный кэш
      #   useCachyKernel = false -> обычное ядро nixpkgs
      # Нужно потому, что NVIDIA legacy_580 (последняя ветка для Pascal)
      # не всегда собирается против слишком нового ядра CachyOS.
      mkSystem = useCachyKernel: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs useCachyKernel; };
        modules = [
          ./configuration.nix
          ./modules/spicetify.nix
          spicetify-nix.nixosModules.spicetify
          tg-ws-proxy.nixosModules.default
          lyricspot.nixosModules.default

          # Десктоп целиком приходит из этого модуля
          ryoku.nixosModules.default
        ];
      };
    in
    {
      nixosConfigurations = {
        nixos = mkSystem true;
        nixos-stable-kernel = mkSystem false;
      };
    };
}
