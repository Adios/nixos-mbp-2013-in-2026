# =============================================================================
# hosts/mbp/home.nix  --  Home Manager side of the example host (GNOME settings + niri)
# =============================================================================
#
# Optional. The hardware profile (../../hardware) does not need Home Manager. This file does
# two MacBook-relevant things: it sets the 200% HiDPI scale for the Retina panel in ONE place
# for both GNOME (dconf) and niri (my.desktop.*), and it wires niri to the GPU rules.
{ config, lib, ... }:

let
  s = import ./settings.nix;
in
{
  imports = [
    ../../modules/home/alacritty.nix
    ../../modules/home/desktop-fonts.nix
    ../../modules/home/desktop-scale.nix
    ../../modules/home/niri.nix
    ../../modules/home/mbp-niri-gpu.nix
  ];

  home.username = s.userName;
  home.homeDirectory = "/home/${s.userName}";
  home.stateVersion = s.stateVersion;

  # ---------------------------------------------------------------------------
  # Shared desktop knobs: ONE place for GNOME (dconf below) and niri
  # (modules/home/desktop-scale.nix explains each of them)
  # ---------------------------------------------------------------------------
  my.desktop = {
    scale = 2;          # 200% for the 2880x1800 Retina panel
    # textScale = 1.0;  # GNOME Accessibility "Large Text" factor, also applied to niri tools
    # cursorSize = 24;
    # touchpad = { speed = 0.0; naturalScroll = true; tapToClick = true; };
    # keyboard = { delay = 500; repeatInterval = 30; };
  };

  # ---------------------------------------------------------------------------
  # GNOME settings (dconf). Everything that has a my.desktop.* knob reads it, so GNOME and
  # niri stay identical.
  # ---------------------------------------------------------------------------
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      # Off to match niri (modules/home/niri.nix); the HD 4000 is happier without them.
      enable-animations = false;
      scaling-factor = lib.hm.gvariant.mkUint32 config.my.desktop.scale;
      text-scaling-factor = lib.hm.gvariant.mkDouble config.my.desktop.textScale;
      cursor-size = config.my.desktop.cursorSize;
      show-battery-percentage = true;
    };

    "org/gnome/desktop/peripherals/touchpad" = {
      # Range: -1.0 (slowest) to 1.0 (fastest)
      speed = lib.hm.gvariant.mkDouble config.my.desktop.touchpad.speed;
      natural-scroll = config.my.desktop.touchpad.naturalScroll;
      tap-to-click = config.my.desktop.touchpad.tapToClick;
    };

    "org/gnome/desktop/peripherals/keyboard" = {
      delay = lib.hm.gvariant.mkUint32 config.my.desktop.keyboard.delay;
      repeat-interval = lib.hm.gvariant.mkUint32 config.my.desktop.keyboard.repeatInterval;
    };
  };
}
