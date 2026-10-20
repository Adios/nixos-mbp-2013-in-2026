# =============================================================================
# modules/home/mbp-niri-gpu.nix  --  niri's GPU rules for this MacBook (Home Manager module)
# =============================================================================
#
# Glue between the hardware profile (../../hardware, read through osConfig) and the generic
# ./niri.nix: niri follows the same boot route as the rest of the machine. See
# hardware/routes.nix for the table of routes and hardware/igd-panel.nix for the isolation.
# Needs Home Manager used as a NixOS module (osConfig) and hardware-fixes.nix imported.
#
# WHY niri NEEDS ITS OWN GPU RULES
#   mutter is told to skip the NVIDIA card by a udev tag (mutter-device-ignore). niri does not
#   read that tag, it opens every DRM device of the seat. Opening a powered-off NVIDIA GPU is
#   exactly what igd-panel.nix says kills it ("a powered-off GPU dies as soon as ANY userspace
#   process touches it"), and a dead GPU breaks suspend. So while the NVIDIA GPU is isolated,
#   niri is told to ignore it. The paths are the stable by-path symlinks (the cardN /
#   renderD12x numbering is not stable); card and render node are both listed because niri
#   keys the ignore list by device node.
#
#   route            igdPanel  isolateNvidia   niri
#   normal           on        on              render on Intel, ignore NVIDIA
#   "desk"           on        off             render on Intel, NVIDIA stays usable (HDMI/DP)
#   "nvidia-panel"   off       (off)           no GPU hints: nouveau drives the panel
#
# VERIFY (normal entry, from a niri session)
#   journalctl --user -b -u niri | grep -iE "drm|ignor|render"   # no NVIDIA device opened
#   sudo dgpu-status                                             # NVIDIA still "Off"
#   several lid-close/open cycles, then: journalctl -k -b | grep -E "nouveau|stalled|PM:"
#   If niri rejects `ignore-drm-device` (niri older than the option), the build fails at
#   `niri validate`; update nixpkgs or drop the option for a test, but then stay out of niri
#   in the normal entry (use GNOME) until it is ignorable.
# =============================================================================

{ lib, osConfig, ... }:

let
  igd = osConfig.mbp.igdPanel;

  intel = "/dev/dri/by-path/pci-0000:00:02.0"; # Intel HD 4000 [8086:0166]
  nvidia = "/dev/dri/by-path/pci-0000:01:00.0"; # NVIDIA GT 650M [10de:0fd5]
in
{
  my.niri = {
    # eDP-1 on the Intel route; eDP-2 appeared on the old nouveau route.
    outputs = [ "eDP-1" "eDP-2" ];

    renderDrmDevice = if igd.enable then "${intel}-render" else null;

    ignoreDrmDevices = lib.optionals (igd.enable && igd.isolateNvidia.enable) [
      "${nvidia}-card"
      "${nvidia}-render"
    ];
  };
}
