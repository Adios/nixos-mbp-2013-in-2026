# =============================================================================
# hosts/mbp/configuration.nix  --  the non-MacBook-specific half of the example host
# =============================================================================
#
# The MacBook fixes live in ../../hardware (imported by flake.nix). This file is an ordinary,
# small desktop configuration: bootloader, swap, filesystems, GNOME + GDM, one user. Replace
# or extend it freely; the hardware profile does not depend on anything below except the
# "video" group (backlight keys under niri).
{ pkgs, ... }:

let
  s = import ./settings.nix;
in
{
  imports = [
    # Generated for YOUR disk by scripts/install.sh (nixos-generate-config). It is not part of
    # this repository on purpose. Flakes only see files known to git: `git add` it.
    ./hardware-configuration.nix
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # ---------------------------------------------------------------------------
  # Boot
  # ---------------------------------------------------------------------------

  # Apple's firmware mostly ignores NVRAM boot entries and uses the fallback
  # EFI/BOOT/BOOTX64.EFI that systemd-boot also installs.
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.systemd-boot.enable = true;
  # Counts generations. Each one shows up to three boot entries (normal, "desk",
  # "nvidia-panel"; see hardware/routes.nix) that share one kernel, so the 1 GB boot
  # partition made by the installer holds three generations comfortably.
  boot.loader.systemd-boot.configurationLimit = 3;

  # ---------------------------------------------------------------------------
  # Memory and disk (matches the btrfs layout made by scripts/install.sh)
  # ---------------------------------------------------------------------------

  # There is no swap partition. zram creates compressed swap inside RAM, which
  # gives breathing room under memory pressure without touching the SSD.
  zramSwap.enable = true;
  # Swapping to zram is cheap because it compresses pages into RAM, with no SSD
  # access. Dropping file cache is the costly choice, because those files have
  # to be re-read from disk later. So with zram, a value like 150 to 180 makes
  # sense. It compresses cold app memory first and keeps your file cache. On a
  # disk-backed swap this would be a bad idea.
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
  };

  services.fstrim.enable = true;

  # The installer creates the btrfs subvolumes @ @home @nix. If you partition differently
  # (ext4, ...), delete this block: compress=zstd would stop an ext4 filesystem from mounting.
  fileSystems = let o = [ "noatime" "compress=zstd:1" ]; in {
    "/".options     = o;
    "/home".options = o;
    "/nix".options  = o;
  };

  # ---------------------------------------------------------------------------
  # Machine, locale, user  (values come from ./settings.nix)
  # ---------------------------------------------------------------------------

  networking.hostName = s.hostName;
  networking.networkmanager.enable = true;

  time.timeZone = s.timeZone;
  i18n.defaultLocale = s.locale;

  users.users.${s.userName} = {
    isNormalUser = true;
    description = s.fullName;
    extraGroups = [
      "networkmanager"
      "wheel"
      "video" # backlight keys in the niri session (brightnessctl)
    ];
  };

  # ---------------------------------------------------------------------------
  # Desktop: GDM lists every installed session (GNOME and niri) and remembers the last one.
  # The niri session itself comes from modules/nixos/niri.nix, imported by flake.nix.
  # ---------------------------------------------------------------------------

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Firefox is here because the software-rendering workaround for the "nvidia-panel" boot
  # entry is a Firefox policy (hardware/hardware-fixes.nix), which only applies when
  # programs.firefox is enabled. Use any other browser if you like.
  programs.firefox.enable = true;

  environment.systemPackages = with pkgs; [
    git
    vim
    pciutils   # lspci
    usbutils   # lsusb
    lm_sensors # sensors
  ];

  system.stateVersion = s.stateVersion;
}
