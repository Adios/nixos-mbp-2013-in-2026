# =============================================================================
# modules/home/desktop-scale.nix  --  shared desktop knobs (GNOME dconf + niri)
# =============================================================================
#
# ONE place for the numbers that must be identical in GNOME and niri. A host sets them
# (see hosts/mbp/home.nix); the consumers read config.my.desktop.*:
#   - the GNOME dconf block in the host's home.nix
#   - modules/home/niri.nix     (output scale, cursor, keyboard/touchpad, bar/launcher fonts)
#   - modules/home/alacritty.nix (terminal font size)
#
# Importing this module only declares options; it changes nothing by itself.
#
# HOW "LARGER TEXT" WORKS PER TOOLKIT
#   textScale is GNOME's Accessibility "Large Text" factor (org.gnome.desktop.interface
#   text-scaling-factor). GTK3/GTK4/libadwaita apps read that dconf key themselves, in ANY
#   compositor, so they get the larger text under niri for free. Everything that does not
#   read it (Alacritty, waybar, fuzzel, mako, swaylock) is multiplied by textScale in Nix.
# =============================================================================

{ lib, ... }:

{
  options.my.desktop = {
    scale = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Integer display scale (200% = 2). GNOME dconf scaling-factor and niri output scale.";
    };

    textScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = ''
        Text scaling factor (GNOME Accessibility "Large Text" = 1.25). Written to dconf, and
        multiplied into the font sizes of apps that do not read dconf (Alacritty, waybar, ...).
      '';
    };

    cursorSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Cursor size (logical pixels) for GNOME dconf cursor-size and niri xcursor-size.";
    };

    monoFont = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "FiraCode Nerd Font Mono";
        description = "Terminal font family (must be installed, see desktop-fonts.nix).";
      };
      size = lib.mkOption {
        type = lib.types.number;
        default = 12;
        description = "Terminal font size in pt BEFORE textScale (what GNOME Console's custom-font used).";
      };
    };

    uiFont = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "Adwaita Sans";
        description = "UI font family for waybar, fuzzel, mako and swaylock.";
      };
      size = lib.mkOption {
        type = lib.types.number;
        default = 11;
        description = "UI font size in pt BEFORE textScale (GNOME's default interface font is 11).";
      };
    };

    touchpad = {
      speed = lib.mkOption {
        type = lib.types.float;
        default = 0.0;
        description = "Pointer speed, -1.0 .. 1.0 (same scale in GNOME and libinput/niri).";
      };
      naturalScroll = lib.mkOption { type = lib.types.bool; default = true; };
      tapToClick = lib.mkOption { type = lib.types.bool; default = true; };
    };

    keyboard = {
      delay = lib.mkOption {
        type = lib.types.ints.positive;
        default = 500;
        description = "Key repeat delay in ms.";
      };
      repeatInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Key repeat interval in ms (GNOME). niri gets the equivalent rate in Hz.";
      };
    };
  };
}
