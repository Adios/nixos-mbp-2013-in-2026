# =============================================================================
# hardware/igd-panel.nix  --  the Intel GPU drives the internal panel
# =============================================================================
#
# WHAT THIS DOES (verified on a MacBookPro10,1, October 2026)
#   The panel sits behind the apple-gmux hardware mux. By default the firmware points that mux
#   at the NVIDIA GPU when Linux is booted via EFI, so nouveau drives the screen all the time
#   (hot, crash-prone, about 24 W at 50% brightness). The firmware reads one EFI variable at
#   boot to decide the mux position:
#       gpu-power-prefs-fa4ce28d-b62f-4c99-9cc3-6815686e30f9
#       raw efivarfs bytes: 07 00 00 00 (attributes) 01 00 00 00 (data)
#       first data byte: 1 = Intel (IGD), 0 = NVIDIA (DIS)
#   (documented in the kernel's apple-gmux driver). This module writes that variable at shutdown,
#   so the NEXT boot starts with the Intel GPU on the panel: i915 shows card?-eDP-1 "connected",
#   vgaswitcheroo shows IGD as "+".
#
#   POWER (battery, 50% brightness), measured:
#       Intel panel, NVIDIA GPU idle (D0)            24-25 W   (same as the nouveau panel)
#       + nouveau.runpm=1 (GPU D3hot, "DynOff")      24-25 W   suspend/resume clean
#       + pure `echo OFF` to vgaswitcheroo, no runpm  ~16.5 W  BUT breaks suspend on its own
#   So the Intel panel by itself is about stability (no more nouveau crashes on the panel), not
#   battery. The battery saving needs the NVIDIA GPU powered off by the gmux. That is what
#   `isolateNvidia` (below) does, and it makes the OFF safe.
#
#   NOT needed (tested): the rEFInd "spoof macOS" USB stick and the acpi_osi=Darwin kernel
#   parameter. The variable alone is enough.
#
# FIRST BOOT AFTER INSTALLING (or after macOS)
#   Nothing has armed the variable yet, so the first Linux boot has the panel on the NVIDIA GPU.
#   Boot the "nvidia-panel" entry (it carries the nouveau workarounds, see ./routes.nix), run
#   `sudo dgpu-arm`, reboot into the normal entry. From then on the shutdown hook keeps it armed.
#
# HOW THE VARIABLE BEHAVES (observed, not documented)
#   - It is consumed at boot: after a boot that used it, it reads "not set".
#   - Linux cannot read it back (EINVAL), even right after writing it. Judge by the result of the
#     NEXT boot, not by reading the variable.
#   - macOS ignores/overwrites it. After booting macOS the next Linux boot comes up with the
#     panel on the NVIDIA GPU again until the variable is armed again.
#
# WHEN IT ARMS
#   - at shutdown/reboot, but ONLY if the Intel GPU drives the panel right now. That is a proof
#     the Intel path works, so a broken boot can never re-arm itself.
#   - mbp.igdPanel.armEveryBoot = true also arms at every boot, even when the panel is on the
#     NVIDIA GPU (handy for a Linux-only machine; the first boot after macOS is still on NVIDIA,
#     the next one is on Intel).
#   - manually: `sudo dgpu-arm`, then reboot (this is the way back after macOS). It works from
#     EVERY boot entry, including "nvidia-panel" (which has igdPanel off, so it does not arm at
#     shutdown by itself, on purpose).
#   - `dgpu-status` shows who drives the panel, GPU power state, and whether the variable is
#     currently set. Like dgpu-arm it is installed in EVERY boot entry (also "nvidia-panel" and
#     when igdPanel is off), because they are most useful on a fallback boot.
#
# RECOVERY (black screen after boot)
#   Power off (hold the power button). Power on holding Cmd+Option+P+R until the chime has played
#   twice: that clears the variable. The next boot is the plain NVIDIA-panel setup and works.
#   Nothing re-arms until i915 proves itself again (or you run dgpu-arm). To give the feature up:
#   set mbp.igdPanel.enable = false and rebuild.
#
# NVIDIA ISOLATION + POWER OFF (mbp.igdPanel.isolateNvidia)
#   Goal: the ~14-16 W state (NVIDIA GPU powered off by the gmux) without breaking suspend.
#   What the sleep and isolation tests showed:
#     - OFF is one-way until a reboot: `echo ON` afterwards cannot bring nouveau back.
#     - A powered-off GPU dies as soon as ANY userspace process touches it. gnome-shell
#       allocated GPU objects on nouveau after OFF, and apps probe render nodes (a GStreamer
#       helper, gst-plugin-scan, did).
#     - With mutter told to ignore the NVIDIA card, its render node denied, nothing holding
#       either node, then OFF once: a 25 s rtcwake suspend/resume was clean (dmesg showed only
#       "PM: suspend entry/exit") and the average draw was 14.4 W.
#   What the option does (service mbp-nvidia-isolate, ordered before display-manager):
#     1. Does nothing unless the Intel GPU (i915) drives a connected eDP panel. After macOS
#        the panel is on the NVIDIA GPU, and ignoring that card would leave GNOME without a
#        display. On such a boot the service waits up to ~15 s for i915, then leaves the
#        NVIDIA GPU alone (the plain NVIDIA-panel setup).
#     2. Checks that no process holds the NVIDIA card/render node.
#     3. Writes /run/udev/rules.d/99-mbp-nvidia-isolate.rules (volatile, gone at reboot):
#        tag mutter-device-ignore on the NVIDIA card; mode 0000 and no uaccess ACL on its
#        render node. Reloads udev, re-triggers drm, then checks the tag and that an
#        unprivileged user cannot open the render node.
#     4. echo OFF to vgaswitcheroo, once. Every failed check BEFORE that removes the rules
#        again and leaves the GPU on (the unit then shows as failed, see the journal). If OFF
#        is written but the GPU is not reported Off, the rules stay: a half-off GPU must not
#        be exposed to userspace.
#     It refuses to run while the display manager is already active, so `nixos-rebuild
#     switch/test` on a live system does nothing: the option takes effect after a REBOOT.
#   Costs and limits:
#     - No HDMI/DP in this boot: those ports belong to the NVIDIA GPU, which is ignored and off.
#     - Root-owned processes ignore file modes. mutter and ordinary user programs are covered;
#       a root daemon that probes GPUs would not be (none seen so far).
#     - niri does not read the mutter udev tag and opens every DRM device it finds. Under niri
#       the isolated GPU must also be listed in niri's ignore list: see
#       ../modules/home/mbp-niri-gpu.nix.
#   Desk mode: while the option is on, option deskSpecialisation adds a boot entry "desk" (a
#     NixOS specialisation) with the isolation off: the NVIDIA GPU stays on, so external monitors
#     can work (24-25 W; HDMI with the Intel panel is untested). Pick it in the boot menu.
#     Switching a RUNNING system to it does not bring a powered-off GPU back; reboot into it
#     instead. Which nouveau workarounds each boot entry has (desk: only WGPU_BACKEND=gl;
#     "nvidia-panel": all) is decided in ./routes.nix.
#   Environment: DRI_PRIME=<Intel> and VK_LOADER_DRIVERS_DISABLE=nouveau* are set session-wide
#     as extra hints for programs that honour them. They are NOT the guard: probing code
#     (Vulkan, EGL, VA-API, GStreamer) enumerates devices regardless. The udev rules are.
#     The Vulkan variable is unverified: check `vulkaninfo --summary` lists no NVK device.
#   VERIFY after the reboot:
#     journalctl -b -u mbp-nvidia-isolate               # "OFF applied", no "ABORT"
#     sudo dgpu-status                                  # DIS ... Off, rules active, node mode 0
#     journalctl -b | grep -i "Ignoring DRM device"     # gnome-shell skipped the NVIDIA card
#     then several lid-close/open cycles with apps open, and
#     journalctl -k -b | grep -E "nouveau|stalled|g84_bar|PM:"   # want only PM: suspend entry/exit
#   UNDO: mbp.igdPanel.isolateNvidia.enable = false, rebuild, reboot (or boot "desk" once).
#
# HARD RULES
#   - Do NOT use a manual `echo OFF > /sys/kernel/debug/vgaswitcheroo/switch` on a running
#     desktop (isolateNvidia does it at boot, see above). It does save about 8 W, but OFF
#     followed by a lid-close suspend produced nouveau "timer: stalled at ffffffffffffffff" and
#     g84_bar_flush warnings (from gnome-shell) after resume, and, once, a complete freeze. A
#     2012 kernel bug report (bugzilla 44391) describes the same hang and says the card is
#     disabled properly after suspend with nouveau.runpm=1. Kernel docs: when the driver's
#     runtime PM controls the power state, writing ON/OFF to that file is a no-op.
#   - nouveau runtime PM (mbp.igdPanel.runtimePm, kernel parameter nouveau.runpm=1) was tested:
#     the NVIDIA GPU suspends (D3hot / DynOff) and lid-close suspend is clean, but power stays
#     at 24-25 W, so it does not deliver the saving. With it on, ON/OFF writes are no-ops, so it
#     cannot be combined with a pure OFF (asserted when isolateNvidia is on).
#   - Userspace can wake or crash the NVIDIA GPU: gst-plugin-scan (a GStreamer helper started
#     by apps) opened the nouveau render node and woke the GPU ("Direct firmware load for
#     nouveau/nve7_fuc084 failed", msvld init failed, gr TRAP RT_HEIGHT_OVERRUN). The same kind
#     of access to a powered-OFF GPU is the suspected cause of the post-resume nouveau
#     errors/freeze. This is what isolateNvidia prevents: mutter ignores the NVIDIA card, its
#     render node is denied (udev MODE="0000" on the 0x10de renderD*), and OFF is applied once
#     at boot.
#   - OFF, then ON before suspend and OFF again after resume does NOT work (after OFF, ON cannot
#     bring nouveau back, its registers read 0xffffffff). OFF is one-way until the next reboot.
#   - Keep nouveau loaded (do not blacklist it): it still owns the HDMI port and the HDMI audio
#     device, and runtime-suspends the idle card.
#   - mbp.nouveauReclock must stay OFF (asserted below): reclocking would heat an idle GPU.
#
# OPEN QUESTIONS (not verified)
#   - Suspend/resume with the Intel panel and the NVIDIA GPU left on is only covered by the
#     nouveau.runpm=1 test; the plain D0 case ("desk" entry) is untested.
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.mbp.igdPanel;
  iso = cfg.isolateNvidia;

  efivar = "/sys/firmware/efi/efivars/gpu-power-prefs-fa4ce28d-b62f-4c99-9cc3-6815686e30f9";

  # PCI path as understood by Mesa's DRI_PRIME.
  intelPrime = "pci-0000_00_02_0"; # Intel HD 4000, [8086:0166]

  # Volatile on purpose (/run): a static rule would also apply on the fallback boot after macOS,
  # where the NVIDIA GPU drives the panel and gnome-shell would be left without a display.
  isolateRules = "/run/udev/rules.d/99-mbp-nvidia-isolate.rules";

  # dgpu-arm: write the boot preference; with --if-igd only when the Intel (i915) card owns a connected eDP panel.
  dgpuArm = pkgs.writeShellScriptBin "dgpu-arm" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.e2fsprogs ]}:$PATH

    igd_has_panel() {
      local c card drv
      for c in /sys/class/drm/card*-eDP-*; do
        [ -e "$c/status" ] || continue
        card=''${c##*/}
        card=''${card%%-*}
        drv=$(basename "$(readlink -f "/sys/class/drm/$card/device/driver")")
        if [ "$drv" = i915 ] && [ "$(cat "$c/status")" = connected ]; then
          return 0
        fi
      done
      return 1
    }

    case "''${1:-}" in
      "")
        ;;
      --if-igd)
        if ! igd_has_panel; then
          echo "dgpu-arm: the Intel GPU does not drive the panel now; not arming" >&2
          exit 0
        fi
        ;;
      *)
        echo "usage: dgpu-arm [--if-igd]" >&2
        exit 2
        ;;
    esac

    var=${efivar}
    if [ -e "$var" ]; then
      chattr -i "$var" 2>/dev/null || true
      rm -f "$var"
    fi
    # One 8-byte write: 4 attribute bytes (NV|BS|RT) + 4 data bytes (01 = Intel).
    printf '\x07\x00\x00\x00\x01\x00\x00\x00' | dd of="$var" bs=8 count=1 conv=notrunc status=none
    echo "dgpu-arm: armed; the firmware applies it at the next boot"
  '';

  dgpuStatus = pkgs.writeShellScriptBin "dgpu-status" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep ]}:$PATH

    echo "== panel connector(s) =="
    for c in /sys/class/drm/card*-eDP-*; do
      [ -e "$c/status" ] || continue
      card=''${c##*/}
      card=''${card%%-*}
      drv=$(basename "$(readlink -f "/sys/class/drm/$card/device/driver")")
      echo "  ''${c##*/}: $(cat "$c/status") (driver: $drv)"
    done

    echo "== GPU power (runtime_status / power_state) =="
    for d in 0000:00:02.0 0000:01:00.0; do
      s=$(cat /sys/bus/pci/devices/$d/power/runtime_status 2>/dev/null || echo "?")
      p=$(cat /sys/bus/pci/devices/$d/power_state 2>/dev/null || echo "?")
      echo "  $d: $s / $p"
    done

    echo "== boot preference variable =="
    if ls /sys/firmware/efi/efivars/ 2>/dev/null | grep -q '^gpu-power-prefs-'; then
      echo "  set in firmware (armed for the next boot)"
    else
      echo "  not set (consumed by the last boot, or never armed)"
    fi

    echo "== NVIDIA isolation (mbp-nvidia-isolate) =="
    if [ -e ${isolateRules} ]; then
      echo "  udev rules active"
    else
      echo "  udev rules not active"
    fi
    for n in /dev/dri/by-path/pci-0000:01:00.0-card /dev/dri/by-path/pci-0000:01:00.0-render; do
      [ -e "$n" ] && echo "  $(basename "$n"): mode/owner $(stat -L -c '%a %U:%G' "$n")"
    done

    if [ -r /sys/kernel/debug/vgaswitcheroo/switch ]; then
      echo "== vgaswitcheroo =="
      sed 's/^/  /' /sys/kernel/debug/vgaswitcheroo/switch
    else
      echo "(run with sudo to also see vgaswitcheroo)"
    fi
  '';

  # Boot-time body of mbp-nvidia-isolate (see "NVIDIA ISOLATION + POWER OFF" in the header).
  # Exit 0 = nothing to do (not applicable), exit 1 = tried and backed out (GPU left on).
  isolateScript = pkgs.writeShellScript "mbp-nvidia-isolate" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.util-linux config.systemd.package ]}

    rules=${isolateRules}
    sw=/sys/kernel/debug/vgaswitcheroo/switch
    nv=0000:01:00.0

    log() { echo "mbp-nvidia-isolate: $*"; }
    abort() { log "ABORT: $*"; exit 1; }

    igd_has_panel() {
      local c card drv
      for c in /sys/class/drm/card*-eDP-*; do
        [ -e "$c/status" ] || continue
        card=''${c##*/}
        card=''${card%%-*}
        drv=$(basename "$(readlink -f "/sys/class/drm/$card/device/driver")")
        if [ "$drv" = i915 ] && [ "$(cat "$c/status")" = connected ]; then
          return 0
        fi
      done
      return 1
    }

    # Processes that have an NVIDIA DRM node open.
    holders() {
      local p fd t
      for p in /proc/[0-9]*; do
        for fd in "$p"/fd/*; do
          t="$(readlink "$fd" 2>/dev/null)" || continue
          if [ "$t" = "$card" ] || [ "$t" = "$render" ]; then
            echo "  pid ''${p#/proc/} ($(cat "$p/comm" 2>/dev/null)) holds $t"
          fi
        done
      done
    }

    undo_rules() {
      rm -f "$rules"
      udevadm control --reload
      udevadm trigger --subsystem-match=drm --action=change
      udevadm settle --timeout=10
    }

    # Opens a node as an unprivileged user (nobody); succeeds if the open worked.
    probe() {
      setpriv --reuid=65534 --regid=65534 --clear-groups ${pkgs.runtimeShell} -c ': < "$1"' sh "$1" 2>/dev/null
    }

    # 1. Boot time only: before the desktop exists, so nobody holds the GPU yet.
    if systemctl is-active --quiet display-manager.service; then
      log "the display manager is already running; this only works at boot. Doing nothing."
      exit 0
    fi
    if grep -q 'nouveau.runpm=1' /proc/cmdline; then
      log "nouveau.runpm=1 is set, so OFF would be a no-op. Doing nothing."
      exit 0
    fi

    # 2. Only when the Intel GPU drives the panel (not after booting macOS).
    n=0
    until igd_has_panel; do
      n=$((n + 1))
      if [ "$n" -ge 15 ]; then
        log "the Intel GPU does not drive the panel (boot after macOS?). Leaving the NVIDIA GPU alone."
        exit 0
      fi
      sleep 1
    done
    log "the Intel GPU drives the panel"

    # 3. The NVIDIA DRM nodes.
    card=""
    render=""
    n=0
    while [ "$n" -lt 15 ]; do
      card="$(readlink -f "/dev/dri/by-path/pci-$nv-card" 2>/dev/null || true)"
      render="$(readlink -f "/dev/dri/by-path/pci-$nv-render" 2>/dev/null || true)"
      if [ -c "$card" ] && [ -c "$render" ]; then
        break
      fi
      n=$((n + 1))
      sleep 1
    done
    if [ ! -c "$card" ] || [ ! -c "$render" ]; then
      log "NVIDIA DRM nodes not found (nouveau not loaded?). Doing nothing."
      exit 0
    fi

    # 4. Nobody may hold them: an open node on a powered-off GPU is what breaks suspend.
    n=0
    while [ -n "$(holders)" ] && [ "$n" -lt 5 ]; do
      n=$((n + 1))
      sleep 1
    done
    h="$(holders)"
    if [ -n "$h" ]; then
      log "$h"
      abort "something holds an NVIDIA DRM node; not isolating, GPU left on"
    fi

    # 5. Volatile udev rules: mutter ignores the NVIDIA card, nobody may open its render node.
    mkdir -p /run/udev/rules.d
    {
      echo '# written by mbp-nvidia-isolate at boot; volatile on purpose (see igd-panel.nix)'
      echo 'SUBSYSTEM=="drm", KERNEL=="card[0-9]*", SUBSYSTEMS=="pci", ATTRS{vendor}=="0x10de", TAG+="mutter-device-ignore"'
      echo 'SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", SUBSYSTEMS=="pci", ATTRS{vendor}=="0x10de", TAG-="uaccess", MODE="0000"'
    } > "$rules"
    udevadm control --reload
    udevadm trigger --subsystem-match=drm --action=change
    udevadm settle --timeout=10

    # 6. Verify the rules took effect before touching the power state.
    if ! udevadm info -q property -n "$card" | grep -q 'mutter-device-ignore'; then
      undo_rules
      abort "mutter-device-ignore tag missing on $card; rules removed"
    fi
    log "mutter will ignore $card"
    if ! probe /dev/null; then
      log "WARNING: unprivileged probe is unavailable, skipping the render-node check"
    elif probe "$render"; then
      undo_rules
      abort "an unprivileged user can still open $render; rules removed"
    else
      log "render node denied to unprivileged users ($(stat -c '%a %U:%G' "$render"))"
    fi

    # 7. Power the NVIDIA GPU off, once. There is no way back to ON before the next reboot.
    if [ ! -w "$sw" ]; then
      undo_rules
      abort "$sw is not writable"
    fi
    if ! echo OFF > "$sw"; then
      undo_rules
      abort "writing OFF failed"
    fi
    sleep 3
    if grep -qE '^[0-9]+:DIS: :Off:' "$sw"; then
      log "OFF applied: $(grep -E ':DIS' "$sw" | tr '\n' ' ')"
    else
      abort "the NVIDIA GPU is not reported Off: $(grep -E ':DIS' "$sw" | tr '\n' ' ')"
    fi
    exit 0
  '';
in
{
  options.mbp.igdPanel = {
    enable = lib.mkEnableOption "the Intel GPU driving the internal panel (apple-gmux boot preference)";

    runtimePm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add the kernel parameter nouveau.runpm=1 so that nouveau's runtime PM suspends the idle
        NVIDIA GPU (D3hot, "DynOff") and suspend/resume stays clean. Measured: it does NOT lower
        the power draw (24-25 W, same as without), and it turns vgaswitcheroo ON/OFF writes into
        no-ops, so it cannot be combined with a pure OFF. Leave it false unless you want that
        suspend-safe baseline.
      '';
    };

    armEveryBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Also arm the boot preference at every boot, even when the panel is currently on the
        NVIDIA GPU (for example the first boot after macOS). Off by default: with it on, a
        boot that cannot drive the panel from the Intel GPU re-arms itself, so after a black
        screen you would have to reset NVRAM again.
      '';
    };

    isolateNvidia.enable = lib.mkEnableOption ''
      keeping userspace away from the NVIDIA GPU and powering it off once at boot (about 14-16 W
      instead of 24-25 W). Boot time only, skipped automatically when the Intel GPU does not
      drive the panel. Disables HDMI/DP in that boot; see "NVIDIA ISOLATION + POWER OFF" in
      hosts/mbp/igd-panel.nix
    '';

    isolateNvidia.deskSpecialisation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        While isolateNvidia is on, also build a boot entry "desk" (a NixOS specialisation) with
        the isolation switched off, so the NVIDIA GPU stays on and external monitors can work.
      '';
    };
  };

  config = lib.mkMerge [
    # Always installed, in every boot entry, also when igdPanel is off (e.g. "nvidia-panel"):
    # a fallback boot is exactly when they are needed (status to look, arm to get back to Intel).
    { environment.systemPackages = [ dgpuStatus dgpuArm ]; }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = !config.mbp.nouveauReclock.enable;
          message = "mbp.igdPanel: nouveauReclock would clock up the idle NVIDIA GPU; turn it off.";
        }
        {
          assertion = !(iso.enable && cfg.runtimePm.enable);
          message = "mbp.igdPanel.isolateNvidia: runtimePm (nouveau.runpm=1) turns the vgaswitcheroo OFF into a no-op; turn runtimePm off.";
        }
      ];

      boot.kernelParams = lib.mkIf cfg.runtimePm.enable [ "nouveau.runpm=1" ];

      # Arms the preference when the system goes down (ExecStop), and optionally at boot.
      systemd.services.mbp-igd-arm = {
        description = "Arm the apple-gmux boot preference (Intel GPU drives the panel next boot)";
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = "/sys/firmware/efi/efivars";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart =
            if cfg.armEveryBoot
            then "${dgpuArm}/bin/dgpu-arm"
            else "${pkgs.coreutils}/bin/true";
          ExecStop = "${dgpuArm}/bin/dgpu-arm --if-igd";
          TimeoutStopSec = "15s";
        };
      };

      # --- NVIDIA isolation + power off (isolateNvidia) -----------------------------------------

      # Hints for programs that honour them. NOT the guard: probing ignores them (see header).
      environment.sessionVariables = lib.mkIf iso.enable {
        DRI_PRIME = lib.mkDefault intelPrime;
        VK_LOADER_DRIVERS_DISABLE = "nouveau*";
      };

      # Runs once at boot, before the desktop exists. Never restarted by a rebuild: it only works
      # at boot, and stopping it would not bring the GPU back anyway.
      systemd.services.mbp-nvidia-isolate = lib.mkIf iso.enable {
        description = "Keep userspace away from the NVIDIA GPU and power it off (Intel GPU drives the panel)";
        wantedBy = [ "multi-user.target" ];
        before = [ "display-manager.service" ];
        after = [ "systemd-udevd.service" "systemd-modules-load.service" ];
        unitConfig.RequiresMountsFor = "/sys/kernel/debug";
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = isolateScript;
          TimeoutStartSec = 90;
        };
      };

      # Boot entry "desk": same system, isolation off (GPU stays on for external monitors). Only
      # defined while the isolation is on, so the specialisation itself has none (no recursion).
      specialisation = lib.mkIf (iso.enable && iso.deskSpecialisation) {
        desk.configuration = {
          system.nixos.tags = [ "desk" ];
          mbp.igdPanel.isolateNvidia.enable = lib.mkForce false;
        };
      };
    })
  ];
}
