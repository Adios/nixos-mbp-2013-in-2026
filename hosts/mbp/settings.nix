# =============================================================================
# hosts/mbp/settings.nix  --  the ONLY file most people have to edit
# =============================================================================
#
# Plain values, read by flake.nix, configuration.nix, home.nix and scripts/install.sh.
# Edit them BEFORE you run the installer (the installer creates this user and asks for the
# password). Keep every value a simple "quoted string" on its own line: the installer reads
# hostName and userName with sed.
{
  hostName = "mbp";
  userName = "user";
  fullName = "MacBook User";

  timeZone = "UTC";                 # e.g. "Europe/Berlin", see `timedatectl list-timezones`
  locale = "en_US.UTF-8";

  # The NixOS release you install with. Set it once and never change it afterwards: it does
  # not upgrade anything, it only keeps old on-disk state formats readable.
  stateVersion = "26.11";
}
