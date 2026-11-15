{ ... }:

# Окружение NVIDIA для Wayland.
# Раньше это лежало в modules/environment/hyprland.nix вместе с
# programs.hyprland, порталами и hyprland-session.target. Теперь композитор и
# порталы принадлежат Ryoku (он жёстко закрепляет свои сборки Hyprland и
# xdg-desktop-portal-hyprland ради совместимости ABI плагинов), а переменные
# остаются за хостом.
{
  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "nvidia";
    GBM_BACKEND = "nvidia-drm";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    NIXOS_OZONE_WL = "1";

    # nvidia-vaapi-driver: прямой backend работает на Pascal/GTX 1050 и
    # включает аппаратное декодирование видео в Firefox/Chromium.
    NVD_BACKEND = "direct";
  };

  # Убрано осознанно:
  #   XDG_SESSION_TYPE = "wayland" — logind выставляет сам; глобально ломает
  #     X11/Xwayland-приложения, которые ждут x11.
  #   XCURSOR_THEME / XCURSOR_SIZE — курсором управляет Ryoku
  #     (ryoku-cursor-material + Hyprland env), ручное значение с ним спорит.
}
