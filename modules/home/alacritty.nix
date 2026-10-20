# =============================================================================
# modules/home/alacritty.nix  --  Alacritty as THE terminal (GNOME and niri)
# =============================================================================
#
# FONT SIZE
#   Alacritty does not read GNOME's text-scaling-factor, so the factor is multiplied in here:
#   size = my.desktop.monoFont.size * my.desktop.textScale. To change it, edit my.desktop.*
#   in the host's home.nix (or set programs.alacritty.settings.font.size). The 200% display
#   scale needs nothing here: Alacritty takes it from the compositor.
# =============================================================================

{ config, ... }:

let
  desk = config.my.desktop;
in
{
  imports = [ ./desktop-scale.nix ];

  programs.alacritty = {
    enable = true;
    settings = {
      font = {
        normal = {
          family = desk.monoFont.name;
          style = "Regular";
        };
        size = desk.monoFont.size * desk.textScale;
      };

      window = {
        padding = { x = 8; y = 8; };
        dynamic_padding = true;
      };

      scrolling.history = 10000;
      mouse.hide_when_typing = true;

      # Solarized Dark (https://ethanschoonover.com/solarized/), spelled out so it does not
      # depend on the alacritty-theme package or on a recent Home Manager `theme` option.
      colors = {
        primary = {
          background = "#002b36"; # base03
          foreground = "#839496"; # base0
        };
        cursor = {
          text = "#002b36";
          cursor = "#839496";
        };
        normal = {
          black = "#073642"; # base02
          red = "#dc322f";
          green = "#859900";
          yellow = "#b58900";
          blue = "#268bd2";
          magenta = "#d33682";
          cyan = "#2aa198";
          white = "#eee8d5"; # base2
        };
        bright = {
          black = "#002b36"; # base03
          red = "#cb4b16"; # orange
          green = "#586e75"; # base01
          yellow = "#657b83"; # base00
          blue = "#839496"; # base0
          magenta = "#6c71c4"; # violet
          cyan = "#93a1a1"; # base1
          white = "#fdf6e3"; # base3
        };
      };
    };
  };

  # "The terminal" for GNOME: Ctrl+Alt+T (gnome-settings-daemon) and tools that read the
  # legacy gsettings key. xdg-terminals.list is read by xdg-terminal-exec-style launchers.
  dconf.settings."org/gnome/desktop/default-applications/terminal" = {
    exec = "alacritty";
    exec-arg = "-e";
  };
  xdg.configFile."xdg-terminals.list".text = "Alacritty.desktop\n";
}
