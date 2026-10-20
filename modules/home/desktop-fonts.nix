# =============================================================================
# modules/home/desktop-fonts.nix  --  the fonts the niri session and Alacritty expect
# =============================================================================
#
# my.desktop.uiFont ("Adwaita Sans") and my.desktop.monoFont ("FiraCode Nerd Font Mono") must
# be installed; this module does that. If you change those options, change the packages here.
{ pkgs, ... }:

{
  home.packages = [
    pkgs.adwaita-fonts        # "Adwaita Sans", GNOME's UI font (a tweaked Inter build)
    pkgs.nerd-fonts.fira-code # monospace font of the terminal
    pkgs.wl-clipboard
  ];

  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      sansSerif = [ "Adwaita Sans" ];
      monospace = [ "FiraCode Nerd Font Mono" ];
    };
  };
}
