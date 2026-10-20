# =============================================================================
# modules/nixos/niri.nix  --  niri session, system side
# =============================================================================
#
# Adds a "niri" session next to GNOME. Which greeter shows it is the HOST's decision (gdm is
# enabled in hosts/mbp/configuration.nix); this module only provides the session.
# The user side (config.kdl, bar, launcher, ...) is modules/home/niri.nix.
#
# WHY NixOS AND NOT HOME MANAGER FOR THESE PIECES
#   A session entry for the display manager, portals, PAM services, udev rules and the
#   Xwayland helper are system things. Per-user tools and their config live in Home Manager.
#
# WHAT programs.niri ALREADY DOES (nixpkgs): installs niri and its session file, enables
#   polkit, gnome-keyring (secret service) and xdg-desktop-portal-gnome (screencast), and
#   Nautilus as the file chooser behind the portal (GNOME is installed here anyway).
#
# MacBook-SPECIFIC BITS
#   brightnessctl's udev rules (backlight and keyboard backlight keys for the "video" group) and
#   the GPU rules in modules/home/mbp-niri-gpu.nix: under niri the isolated NVIDIA GPU must be
#   ignored explicitly, see hardware/igd-panel.nix.
# =============================================================================

{ pkgs, ... }:

{
  programs.niri.enable = true;

  # NixOS otherwise puts a stripped PATH on niri.service that shadows the full PATH imported
  # by niri-session; apps started from fuzzel would not find their tools.
  # https://wiki.nixos.org/wiki/Niri
  systemd.user.services.niri.enableDefaultPath = false;

  # X11 apps: niri starts xwayland-satellite on demand when it finds it in PATH.
  environment.systemPackages = [ pkgs.xwayland-satellite ];

  # swaylock must be able to verify the password.
  security.pam.services.swaylock = { };

  # Backlight keys (F1/F2 screen, F5/F6 keyboard) use brightnessctl; its udev rules make the
  # backlight writable for the "video" group (the example user is in it, see hosts/mbp/configuration.nix).
  services.udev.packages = [ pkgs.brightnessctl ];

  # Electron/Chromium apps on Wayland instead of blurry Xwayland at 200%.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
}
