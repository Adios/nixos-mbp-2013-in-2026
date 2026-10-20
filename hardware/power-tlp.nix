# =============================================================================
# hardware/power-tlp.nix  --  TLP power policy (low heat, long battery) + 80% charge cap
# =============================================================================
#
# Imported from hardware-fixes.nix. Active only while a battery is installed
# (mbp.noBattery.enable = false); no-battery mode keeps its own static policy (no-battery.nix).
#
# WHAT THIS DOES
#   1. TLP replaces power-profiles-daemon (PPD). They cannot run together, so PPD is forced off
#      here. tlp-pd (TLP >= 1.9) implements PPD's D-Bus API, so GNOME's "Power Mode" switch
#      (Settings > Power) keeps working with TLP behind it. (COSMIC's power applet was NOT
#      checked against tlp-pd.)
#   2. The battery is capped at 80% by a small userspace tool, NOT by TLP (see below).
#
# THE POLICY (priority: low heat first, battery life second)
#   TLP 1.10 has three profiles. Their settings keep legacy suffixes:
#     Performance (PRF) = *_ON_AC     Balanced (BAL) = *_ON_BAT     Power Saver (SAV) = *_ON_SAV
#   Automatic choice: on AC -> Balanced, on battery -> Power Saver (TLP_PROFILE_AC/BAT).
#   You can still pick any profile in GNOME's Power Mode switch (TLP_AUTO_SWITCH=2, "smart",
#   keeps a manual choice until the power source changes).
#
#                      Performance           Balanced           Power Saver
#   Turbo Boost        allowed               OFF                OFF
#   CPU energy bias    balance_performance   balance_power      power
#   Intel GPU max      hardware default      800 MHz            (no GPU setting for this profile)
#
#   WHY turbo off: once the battery was installed (turbo no longer locked off) the laptop ran
#   considerably warmer. Turbo is the biggest single heat source of this 45 W quad-core in a thin
#   chassis. Pick "Performance" in the GNOME switch when you really need peak speed.
#   WHY an Intel GPU cap: the Intel HD 4000 renders the whole desktop in the default setup and
#   shares the CPU's thermal budget. 800 MHz is far below
#   its maximum (about 1150-1250 MHz depending on the CPU) but plenty for desktop work. Tune with
#   `sudo tlp-stat -g` (lists the valid frequencies).
#
#   CPU SCALING GOVERNOR: deliberately NOT set. This Ivy Bridge CPU has no HWP, so since kernel 5.7
#   intel_pstate runs in PASSIVE mode (scaling_driver = intel_cpufreq) and the kernel default is
#   the schedutil governor. In that mode the generic "powersave" governor pins the LOWEST
#   frequency (about 800 MHz) instead of scaling, so never set "powersave" here. Energy bias (EPB,
#   Sandy Bridge and newer) and the turbo switch work without touching the governor. Max-frequency
#   limits are not used either: TLP's own docs say lowering the max on battery may not save power.
#   Check the real state with `sudo tlp-stat -p`.
#
#   WI-FI POWER SAVING is off. The proprietary "wl" driver is the fragile part of this machine
#   and the saving is small. Try "on" for BAT if you want to experiment.
#
#   Left at TLP defaults on purpose: disks (Apple PCIe SSD), USB autosuspend, audio, runtime PM
#   (TLP already denylists nouveau, nvidia and pcieport), PCIe ASPM (Apple's FADT may forbid it).
#
# DAEMON CLEANUP
#   - power-profiles-daemon: forced off (above).
#   - thermald (hardware-fixes.nix): kept; it works alongside TLP and is a useful heat safety net.
#   - NOT used and must stay unset/disabled: powerManagement.cpuFreqGovernor (asserted below),
#     powerManagement.powertop, services.auto-cpufreq, services.tuned.
#   - mbpfan (Mac fan curve daemon) is optional and not enabled; the SMC controls the fans.
#
# 80% CHARGE CAP -- WHY NOT TLP
#   TLP only sets thresholds through a kernel interface (charge_control_end_threshold). The mainline
#   kernel has none for Intel Macs: the applesmc patches that add it (with an ACPI sbs hook) were
#   still pending review in Sept 2026, and TLP's Apple plugin only handles Apple Silicon
#   ("macsmc-battery"). So the cap is applied by `macbook-charge-limit` (see ./pkgs), which writes
#   the SMC keys BCLM and BFCL, from a boot-time service that is also re-run after resume.
#   VERIFIED ON A MacBookPro10,1 (2026-10-05): upstream tested a MacBookAir6,2 only, but on the
#   MacBookPro10,1 the battery stops at 80% on AC (charge current 0.00 A). To re-check:
#     sudo macbook-charge-limit read          # expect: BCLM=80 BFCL=80
#     Let the battery fall below 80%, plug in AC, and watch it stop near 80%:
#       watch -n 10 'cd /sys/class/power_supply/BAT0 && cat status capacity current_now'
#     (current_now = 0 and status Full/Not charging at ~80% means the cap works.)
#   The limit never DISCHARGES a fuller battery; it only stops charging.
#   FULL CHARGE (travel):  sudo macbook-charge-limit reset   (100% until you run:
#                          sudo systemctl restart macbook-charge-limit)
#   WHEN THE KERNEL GAINS SUPPORT (BAT0/charge_control_end_threshold appears): delete the service and
#   the ./pkgs file, and try STOP_CHARGE_THRESH_BAT0 = 80 in the TLP settings (check `tlp-stat -b`).
#
# VERIFY AFTER `nixos-rebuild test`
#   systemctl status tlp tlp-pd macbook-charge-limit
#   sudo tlp-stat -s -c        # TLP running, effective config
#   sudo tlp-stat -p           # CPU: driver, governor (schedutil), EPB, turbo (should be off in Balanced)
#   sudo tlp-stat -g           # Intel GPU frequency range and limits
#   GNOME Settings > Power > Power Mode shows Balanced / Power Saver / Performance
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg       = config.mbp.tlp;
  limit     = config.mbp.chargeLimit;
  noBattery = config.mbp.noBattery.enable;
  chargeLimitTool = pkgs.callPackage ./pkgs/macbook-charge-limit.nix { };
in
{
  options.mbp.tlp.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Manage power with TLP (+ tlp-pd for GNOME's Power Mode switch) instead of
      power-profiles-daemon. Ignored (TLP off) while mbp.noBattery.enable is true.
    '';
  };

  options.mbp.chargeLimit = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Cap battery charging with the userspace macbook-charge-limit tool (Apple SMC BCLM/BFCL).
        Verified on MacBookPro10,1 (2026-10-05): charging stops at the limit on AC. See power-tlp.nix
        for how to re-check.
      '';
    };
    percent = lib.mkOption {
      type = lib.types.ints.between 20 100;
      default = 80;
      description = "Charge stops at this percentage.";
    };
  };

  config = lib.mkMerge [

    # -------------------------------------------------------------------------
    # TLP policy
    # -------------------------------------------------------------------------
    (lib.mkIf (cfg.enable && !noBattery) {
      assertions = [
        {
          assertion = lib.versionAtLeast pkgs.tlp.version "1.10";
          message = ''
            power-tlp.nix needs TLP >= 1.10 (profile-based TLP_PROFILE_AC/BAT settings); nixpkgs
            provides ${pkgs.tlp.version}. Update nixpkgs or set mbp.tlp.enable = false.
          '';
        }
        {
          assertion = config.powerManagement.cpuFreqGovernor == null;
          message = ''
            powerManagement.cpuFreqGovernor is set, but TLP manages the CPU scaling policy and the two
            conflict. Remove that setting (it is only set by old no-battery code).
          '';
        }
      ];

      # TLP and power-profiles-daemon cannot coexist (NixOS asserts this). mkForce also beats
      # GNOME's own mkDefault true and any older explicit `true` elsewhere in the config.
      services.power-profiles-daemon.enable = lib.mkForce false;

      services.tlp = {
        enable = true;
        # PPD-compatible D-Bus daemon so GNOME's "Power Mode" switch keeps working.
        pd.enable = true;

        settings = {
          # Automatic profile choice (TLP 1.10): AC -> Balanced, battery -> Power Saver.
          TLP_PROFILE_AC = "BAL";
          TLP_PROFILE_BAT = "SAV";

          # --- Performance profile (*_ON_AC): the on-demand "fast" mode ---------------------
          CPU_ENERGY_PERF_POLICY_ON_AC = "balance_performance";
          CPU_BOOST_ON_AC = 1;
          # Intel GPU: no cap in this profile (hardware default).

          # --- Balanced profile (*_ON_BAT): everyday mode, also the default on AC -----------
          CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_power";
          CPU_BOOST_ON_BAT = 0;
          INTEL_GPU_MAX_FREQ_ON_BAT = 800;
          INTEL_GPU_BOOST_FREQ_ON_BAT = 800;

          # --- Power Saver profile (*_ON_SAV): default on battery ----------------------------
          CPU_ENERGY_PERF_POLICY_ON_SAV = "power";
          CPU_BOOST_ON_SAV = 0;

          # --- Wi-Fi (proprietary wl driver): no power saving, for stability -----------------
          WIFI_PWR_ON_AC = "off";
          WIFI_PWR_ON_BAT = "off";

          # No CPU_SCALING_GOVERNOR_* and no CPU_MAX_PERF_*: see the header comment.
          # No START/STOP_CHARGE_THRESH_BAT0: no kernel interface on Intel Macs yet.
        };
      };
    })

    # -------------------------------------------------------------------------
    # 80% charge cap (userspace SMC tool)
    # -------------------------------------------------------------------------
    (lib.mkIf (limit.enable && !noBattery) {
      environment.systemPackages = [ chargeLimitTool ];

      systemd.services.macbook-charge-limit = {
        description = "Cap battery charge at ${toString limit.percent}% (Apple SMC BCLM/BFCL)";
        wantedBy = [ "multi-user.target" ];
        # applesmc / msr modules are loaded by systemd-modules-load.
        after = [ "systemd-modules-load.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${chargeLimitTool}/bin/macbook-charge-limit set ${toString limit.percent}";
        };
      };

      # Re-apply after resume as a precaution (the SMC normally keeps the value).
      powerManagement.resumeCommands = ''
        ${config.systemd.package}/bin/systemctl restart macbook-charge-limit.service || true
      '';
    })
  ];
}
