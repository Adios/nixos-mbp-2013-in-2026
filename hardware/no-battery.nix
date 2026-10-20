# =============================================================================
# hardware/no-battery.nix  --  OPT-IN workarounds for running WITHOUT the battery
# =============================================================================
#
# STATUS: DISABLED by default (mbp.noBattery.enable = false).
#   Only for a MacBook whose battery is removed or dead. With a battery installed the CPU runs
#   normally with no throttling and none of this is needed. The whole hack is kept here so it
#   can be switched on in ONE line:
#       mbp.noBattery.enable = true;
#   (this file is imported by hardware-fixes.nix, nothing else needs to change)
#
# WHAT IT DOES WHEN ENABLED
#   1. Clears BD_PROCHOT (bit 0 of MSR 0x1FC) on every CPU at boot and after every resume. This
#      removes the 1.2 GHz CPU throttle that the Mac firmware applies when the battery is missing.
#   2. Locks Turbo Boost OFF. The CPU then runs at its base clock at most: 2.4 or 2.7 GHz
#      depending on the model (the i7-3740QM: 2.7 GHz).
#   3. Turns TLP, power-profiles-daemon and the 80% charge cap off (pointless without a battery).
#      Side effect: GNOME shows no Power Mode toggle while this mode is on.
#
# USE IT TOGETHER WITH THE DEFAULT "INTEL-ONLY" ENTRY (NVIDIA GPU powered off, ./igd-panel.nix)
#   As far as we know the 1.2 GHz limit exists because, without a battery, the power adapter
#   alone has to cover every load peak, and the machine can run into a power shortage. Locking
#   turbo off and keeping the NVIDIA GPU powered off keeps the load inside what the adapter can
#   deliver, which is the reason to combine the two. The "desk" and "nvidia-panel" entries keep
#   the NVIDIA GPU powered, which brings the risk back.
#
# HOW TO VERIFY AFTER ENABLING
#   sudo rdmsr -a 0x1FC                    # last hex digit must be EVEN (e.g. 300046)
#   (suspend, resume, run it again)        # must STILL be even
#   cat /sys/devices/system/cpu/intel_pstate/no_turbo    # 1 = turbo locked off
#   systemctl status cpu-safe-uncap        # "active (exited)"
#
# WHY IT EXISTS
#   A MacBook run without its battery gets heavily throttled. Presumably the Mac's controller
#   (SMC/EC) asserts the CPU's PROCHOT# signal because the battery is missing. Intel CPUs can be
#   told to ignore that signal by clearing bit 0 of MSR 0x1FC (IA32_POWER_CTL, the "BD_PROCHOT"
#   enable bit). The CPU's own internal overheating protection is NOT affected by this bit.
#   Observed: `rdmsr -a 0x1FC` = 300047 (bit 0 set) on all 8 CPUs.
#   CONFIRMED: firmware re-enables the bit during S3 resume and the Linux kernel does not
#   restore MSR 0x1FC, hence the resume hook below.
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.mbp.noBattery;
in
{
  options.mbp.noBattery.enable = lib.mkEnableOption
    "the no-battery workarounds (clear BD_PROCHOT, lock turbo off, PPD off)";

  config = lib.mkIf cfg.enable {

    # The "msr" module exposes CPU model-specific registers to rdmsr/wrmsr.
    # (hardware-fixes.nix also loads it permanently for diagnostics; the
    # duplicate entry is harmless and keeps this file self-contained.)
    boot.kernelModules = [ "msr" ];

    # rdmsr / wrmsr tools (also for checking: `sudo rdmsr -a 0x1FC`).
    environment.systemPackages = [ pkgs.msr-tools ];

    systemd.services.cpu-safe-uncap = {
      description = "Clear BD_PROCHOT";
      wantedBy = [ "multi-user.target" ];
      # The "msr" kernel module (boot.kernelModules above) must be loaded first.
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        # Stays "active" after running, so `systemctl status` shows it did its
        # job. `systemctl restart` still re-runs it (used after resume below).
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "uncap-cpu" ''
          set -euo pipefail
          # Read the register from CPU 0 (rdmsr defaults to CPU 0). Assumes all
          # cores hold the same value; observed 300047 on all 8 CPUs.
          CURRENT_HEX=$( ${pkgs.msr-tools}/bin/rdmsr 0x1FC )
          # Clear bit 0 (BD_PROCHOT enable), keep every other bit unchanged.
          NEW_HEX=$(printf "%x" $(( 0x$CURRENT_HEX & ~1 )))
          # Write the new value to ALL CPUs (-a).
          ${pkgs.msr-tools}/bin/wrmsr -a 0x1FC "0x$NEW_HEX"
        '';
      };
    };

    # Re-apply the uncap after resume from suspend. `rdmsr -a 0x1FC` returned 0x300047
    # (bit 0 set) across all CPUs after resume. Verified that firmware re-enables this bit
    # during S3 resume, and the Linux kernel does not restore MSR 0x1FC automatically.
    powerManagement.resumeCommands = ''
      ${config.systemd.package}/bin/systemctl restart cpu-safe-uncap.service
    '';

    # power-profiles-daemon (behind GNOME's "Power Mode" switch) must be OFF in
    # this mode so it does not fight the manual governor and turbo lock below.
    # hardware-fixes.nix enables it normally, so this needs mkForce.
    # Side effect: GNOME shows no Power Mode toggle while this mode is on.
    # TLP is not used either (it conflicts with PPD; battery/AC profiles are
    # pointless without a battery).
    services.power-profiles-daemon.enable = lib.mkForce false;

    # Governor: deliberately NOT forced to "powersave". On this CPU (Ivy Bridge, no HWP,
    # kernel >= 5.7) intel_pstate runs in PASSIVE mode (scaling_driver = intel_cpufreq), where
    # the generic "powersave" governor pins the LOWEST frequency (about 800 MHz) instead of
    # scaling. The kernel default (schedutil) is used. Check with:
    #   cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver \
    #       /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

    # Lock Turbo Boost off at boot (1 = turbo disabled). Keeps the machine cooler
    # and quieter, and there is no battery that would benefit from a higher peak.
    # To re-enable turbo: set this to 0 (or delete the rule) and rebuild, or test
    # quickly with: echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
    systemd.tmpfiles.rules = [
      "w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 1"
    ];
  };
}
