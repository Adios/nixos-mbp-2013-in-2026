# =============================================================================
# hardware/nouveau-reclock.nix  --  OPTIONAL: reclock the NVIDIA GPU + NVK Vulkan
# =============================================================================
#
# Imported from hardware-fixes.nix. Option: mbp.nouveauReclock.enable (default OFF). EXPERIMENTAL: a bad pstate can blank or hang the screen, because this GPU
# drives the internal panel (apple-gmux mux). A forced power-off (hold the power button) or the
# previous boot generation recovers it.
#
# WHY
#   nouveau cannot raise Kepler GPU clocks automatically (NVIDIA only allows that through its
#   proprietary driver), so the GT 650M normally sits at slow boot clocks. The HD 4000 outruns it in
#   glmark2 (1110 vs 927 windowed, 1152 vs 637 off-screen). nouveau DOES support MANUAL reclocking on Kepler through a debugfs
#   file, /sys/kernel/debug/dri/<card>/pstate, and reports claim roughly 80% of the proprietary
#   driver's speed afterwards (ventureoo/nouveau-reclocking, nouveau.freedesktop.org). Mesa's
#   Vulkan driver NVK has been enabled for Kepler since Mesa 25.2 (Aug 2025); this machine runs
#   Mesa 26.2.3.
#
# RESULT (measured 2026-10-05; glmark2-wayland 800x600)
#   unclocked nouveau 927 | Intel HD 4000 1110 | reclocked, battery (07) 1150 | reclocked, AC (0f) 1845
#   On AC: about 2x unclocked nouveau and +66% over Intel (live clocks 796 MHz core / 5016 MHz memory).
#   Verified on this machine: the service applies both pstates at boot and again when the charger
#   is plugged or unplugged, and NVK lists the card ("GeForce GT 650M (NVK GK107)", Mesa 26.2.3).
#   OBSERVED SIDE EFFECT: the LCD blanks for a fraction of a second when the charger is plugged or
#   unplugged, while the memory clock switches between 838 and 5016 MHz. It is a GPU clock change,
#   not a panel power problem. Using the same pstate for acPstate and dcPstate should avoid it
#   (untested).
#
# WHAT THE OPTION DOES WHEN ENABLED
#   1. Service nouveau-reclock writes one fixed pstate per power source ("dc:" battery, "ac:"
#      plugged in) before the display manager starts. It is re-run when the charger is plugged or
#      unplugged (udev) and after resume (the GPU may fall back to boot clocks).
#   2. NVK is the Vulkan driver (assert: Mesa >= 25.2). vulkan-tools is installed for checking.
#      WGPU_BACKEND=gl stays (mbp.glRenderers.wgpu in ./routes.nix, on whenever nouveau is
#      reachable): NVK on this chip mis-rendered the glyph atlas of COSMIC (wgpu) apps. Set
#      mbp.glRenderers.wgpu.enable = false to try Vulkan for them too.
#   3. nouveau must drive the panel (everything renders on the NVIDIA GPU, at reclocked speeds): mbp.igdPanel.enable has to be OFF (igd-panel.nix asserts).
#      Set mbp.panelGpu = "nvidia" (./routes.nix; then the nouveau workarounds are on too) or
#      mbp.igdPanel.enable = false. Otherwise the Intel route's mkDefault values keep igdPanel on.
#
# HEAT -- READ THIS
#   nouveau has NO automatic downclocking on Kepler. The pstate is FIXED, so "max" means the GPU
#   runs at full clocks, and makes full heat and fan noise, even when idle. That fights the low
#   heat goal of power-tlp.nix (TLP does not manage the NVIDIA GPU). Defaults: AC = "max",
#   battery = "min". If it runs too hot on AC, set acPstate to a middle id (e.g. "0a" or "0e").
#
# TRY IT BY HAND BEFORE ENABLING (all reversible at runtime; a hang needs a forced power-off)
#   sudo cat /sys/kernel/debug/dri/*:*/pstate        # lists pstates; "*" = current. Note the ids.
#       typical shape:  07: core 270-405 MHz memory 838 MHz AC DC *
#                       0f: core 270-900 MHz memory 5016 MHz
#   echo 0a | sudo tee /sys/kernel/debug/dri/0/pstate     # try a middle one (the "0" may be
#                                                         # another number or a PCI address)
#   echo 0f | sudo tee /sys/kernel/debug/dri/0/pstate     # then the top one
#   echo auto | sudo tee /sys/kernel/debug/dri/0/pstate   # undo (or: echo 07 for the lowest)
#   If the screen glitches or goes black at a high MEMORY clock, use a lower pstate for AC.
#   If the pstate file does not exist: nouveau is not loaded, debugfs is missing, or the kernel
#   was built without nouveau's debugfs; this module then does nothing (the service says so).
#   Then measure:  nix shell nixpkgs#glmark2 -c glmark2-wayland   (before: nouveau 927, Intel 1110)
#
# VERIFY AFTER `nixos-rebuild test` WITH THE OPTION ON
#   systemctl status nouveau-reclock ; journalctl -u nouveau-reclock
#   sudo cat /sys/kernel/debug/dri/*:*/pstate      # "*" on the chosen pstate for the current source
#   vulkaninfo --summary                         # should list NVK for the GT 650M
#   sensors                                      # watch the temperatures
#
# ALTERNATIVE (not used here): kernel parameter nouveau.config=NvClkMode=<decimal pstate>
# (0x0f = 15); NvClkModeAC / NvClkModeDC set the two power sources separately. It applies while
# nouveau initialises, but needs a reboot to change and a bad value breaks the boot display. The
# upstream Lua tool's --save mode makes its setting permanent through a modprobe.d file instead.
# Memory reclocking can also be controlled by NvMemExec; it is not touched here.
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.mbp.nouveauReclock;

  # Writes the AC/battery pstates into nouveau's debugfs file(s). /sys/kernel/debug/dri/ holds one
  # directory per GPU named by PCI address (e.g. 0000:01:00.0) plus numeric entries (0, 1, 128, 129)
  # that expose the same devices (dri/0 and dri/129 printed identical pstate output). Only the
  # PCI-named directories are matched here, so each GPU is handled once; the Intel GPU has no
  # "pstate" file and is skipped. Exits 0 on every "nothing to do" case so a missing interface
  # never fails the boot.
  applyScript = pkgs.writeShellScript "nouveau-reclock-apply" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep ]}
    AC_WANT='${cfg.acPstate}'
    DC_WANT='${cfg.dcPstate}'

    # nouveau is loaded asynchronously by udev; its debugfs node appears when init finishes.
    found=""
    for i in $(seq 1 10); do
      for f in /sys/kernel/debug/dri/*:*/pstate; do
        [ -e "$f" ] && found=1
      done
      [ -n "$found" ] && break
      sleep 1
    done
    if [ -z "$found" ]; then
      echo "nouveau-reclock: no pstate interface (nouveau not loaded, debugfs not mounted or unsupported); nothing to do"
      exit 0
    fi

    # Ids are lowercase hex ("07", "0f"). The "AC:"/"DC:" summary lines are uppercase and
    # are NOT matched (grep is case-sensitive on purpose).
    resolve() { # file want
      ids="$(grep -oE '^[0-9a-f]{2}: ' "$1" | tr -d ': ' | sort)"
      case "$2" in
        max) printf '%s\n' "$ids" | tail -n 1 ;;
        min) printf '%s\n' "$ids" | head -n 1 ;;
        *)   printf '%s\n' "$2" ;;
      esac
    }

    for f in /sys/kernel/debug/dri/*:*/pstate; do
      [ -e "$f" ] || continue
      echo "nouveau-reclock: $f before:"
      cat "$f"
      ac="$(resolve "$f" "$AC_WANT")"
      dc="$(resolve "$f" "$DC_WANT")"
      if [ -z "$ac" ] || [ -z "$dc" ]; then
        echo "nouveau-reclock: could not determine pstate ids for $f; skipping"
        continue
      fi
      # Battery first, then AC; nouveau applies the one matching the current power source.
      echo "dc:$dc" > "$f" || echo "nouveau-reclock: WARNING: writing dc:$dc failed"
      echo "ac:$ac" > "$f" || echo "nouveau-reclock: WARNING: writing ac:$ac failed"
      echo "nouveau-reclock: $f after (battery=$dc, ac=$ac):"
      cat "$f"
    done
    exit 0
  '';
in
{
  options.mbp.nouveauReclock = {
    enable = lib.mkEnableOption ''
      manual reclocking of the NVIDIA GPU through nouveau pstates plus NVK Vulkan, with the Intel
      GPU routing experiment forced off. EXPERIMENTAL and runs the GPU hotter; read
      hardware/nouveau-reclock.nix first
    '';

    acPstate = lib.mkOption {
      type = lib.types.strMatching "max|min|[0-9a-f]{2}";
      default = "max";
      description = ''
        Pstate while on AC: "max" (highest id listed by the pstate file), "min", or an explicit
        two-digit lowercase hex id such as "0e". The pstate is fixed (no automatic
        downclocking), so "max" means full heat all the time.
      '';
    };

    dcPstate = lib.mkOption {
      type = lib.types.strMatching "max|min|[0-9a-f]{2}";
      default = "min";
      description = "Pstate on battery power; same values as acPstate.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.versionAtLeast pkgs.mesa.version "25.2";
        message = ''
          mbp.nouveauReclock needs Mesa >= 25.2 (NVK for Kepler), nixpkgs provides ${pkgs.mesa.version}.
        '';
      }
    ];

    # GNOME already enables this; stated here so the Vulkan ICDs (NVK) are always installed.
    hardware.graphics.enable = lib.mkDefault true;

    # vulkaninfo --summary shows whether NVK sees the GT 650M.
    environment.systemPackages = [ pkgs.vulkan-tools ];

    systemd.services.nouveau-reclock = {
      description = "Reclock the NVIDIA GPU through nouveau pstates (AC/battery)";
      wantedBy = [ "multi-user.target" ];
      # Reclock before the compositor starts (less risk than switching clocks under load).
      before = [ "display-manager.service" ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = applyScript;
        TimeoutStartSec = 30;
      };
    };

    # Re-apply when the charger is plugged or unplugged, so the matching pstate is selected.
    services.udev.extraRules = ''
      SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="Mains", RUN+="${config.systemd.package}/bin/systemctl --no-block start nouveau-reclock.service"
    '';

    # The GPU may come back from suspend at boot clocks; re-apply (unverified whether needed).
    powerManagement.resumeCommands = ''
      ${config.systemd.package}/bin/systemctl --no-block start nouveau-reclock.service || true
    '';
  };
}
