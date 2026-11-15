{ ... }:

# Интеграция Ryoku в этот флейк.
# Модуль сам приносит: Hyprland/niri/MangoWM из своего закреплённого nixpkgs,
# оболочку Quickshell, Hub, Ryostore, SDDM-тему, порталы, user-сервисы и
# materialization конфигов в ~/.config.
{
  programs.ryoku = {
    enable = true;

    # Стартовая сессия в логин-менеджере. Все три остаются доступны,
    # переключение — через Hub, без пересборки.
    defaultCompositor = "hyprland";

    # null = браузер остаётся за хостом. Роль "browser" в Ryoku возьмёт
    # firefox из PATH (он у тебя уже есть), и второй Firefox не установится.
    browser = null;

    # Тот же fish, что у пользователя steelium.
    shell = "fish";

    # Флейк, чей input `ryoku` будет обновлять `ryoku update` из Hub.
    # Если репозиторий лежит не в /etc/nixos — поменяй путь.
    updateFlake = "/etc/nixos";
  };
}
