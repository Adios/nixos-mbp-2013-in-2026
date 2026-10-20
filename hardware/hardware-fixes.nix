# =============================================================================
# hardware/hardware-fixes.nix  --  MacBook Pro 15" Retina, Early 2013 (MacBookPro10,1)
# =============================================================================
#
# ENTRY POINT of the hardware profile: import this one file, it pulls in the rest.
# Importing it switches the recommended setup on (Intel GPU drives the panel, NVIDIA GPU
# powered off, TLP, 80% charge cap). Every default can be overridden, see the README.
#
# MACHINE
#   - Intel HD Graphics 4000 (Ivy Bridge)  PCI 00:02.0 [8086:0166]
#   - NVIDIA GeForce GT 650M (GK107)       PCI 01:00.0 [10de:0fd5]
#   - apple-gmux: hardware mux that decides which GPU drives the internal panel
#   - Broadcom Wi-Fi that needs the proprietary "wl" driver
#   - Tested October 2026: nixos-unstable, kernel = linuxPackages_latest, GNOME (Wayland)
#     and niri.
#
# WHERE THINGS LIVE
#   ./igd-panel.nix        Intel GPU drives the panel (EFI boot preference), NVIDIA isolation,
#                          `dgpu-arm` / `dgpu-status`. Read its header first.
#   ./routes.nix           Everything that depends on WHICH GPU drives the panel (boot entries
#                          "desk" / "nvidia-panel", software rendering, GSK_RENDERER, WGPU_BACKEND).
#   ./power-tlp.nix        TLP power management, 80% charge cap.
#   ./nouveau-reclock.nix  Optional manual reclocking of the NVIDIA GPU (default OFF).
#   ./no-battery.nix       Opt-in workaround for running without a battery (default OFF).
#   ./pkgs/                macbook-charge-limit (userspace tool for the Apple SMC charge limit).
#   This file              Kernel, Wi-Fi, firmware, thermald, and the software-rendering switches.
#
# THE KEY FACT
#   The panel sits behind the apple-gmux mux. When Linux boots via EFI the firmware points the
#   mux at the NVIDIA GPU unless the gpu-power-prefs EFI variable says otherwise (igd-panel.nix).
#   So:
#     - NEVER blacklist nouveau or set nouveau.modeset=0: in a boot where the panel is on the
#       NVIDIA GPU, that breaks lid suspend, brightness and wake all at once.
#     - NEVER set acpi_backlight=native: since Linux 6.1 it hides gmux_backlight, the device that
#       controls this panel. If brightness breaks, check `cat /proc/cmdline` first.
#     - Do NOT add mem_sleep_default overrides or services.logind / GNOME lid-close settings.
#       The defaults (suspend on lid close) are what we want.
#     - Do NOT use hardware.nvidia / PRIME from the NixOS wiki: that is for the proprietary
#       driver on laptops where Intel drives the panel, and Kepler only has the EOL legacy_470,
#       which has no usable Wayland support.
#
# QUICK HEALTH CHECK (run any time something feels wrong)
#   ls /sys/class/drm/                                # want eDP-1; no Unknown-1
#   dgpu-status                                       # who drives the panel (want i915), GPU power
#   systemctl status mbp-nvidia-isolate               # NVIDIA isolation + OFF at boot
#   readlink -f /run/booted-system                    # which entry: "-desk-" / "-nvidia-panel-" in name
#   env | grep -E 'GSK_RENDERER|WGPU_BACKEND|QT_QUICK'   # normal: empty; desk: WGPU only; nvidia-panel: all
#   ls /sys/class/backlight/                          # want gmux_backlight
#   cat /proc/cmdline                                 # no acpi_backlight=, no nouveau.modeset=0
#   systemd-inhibit --list --mode=block | grep lid    # want NO output
#   journalctl -b | grep -E "Lid |PM: suspend"        # lid + suspend entry/exit
#   journalctl -k -b | grep -iE "i915|nouveau|gmux"   # GPU driver messages
#   sudo rdmsr -a 0x1FC                               # diagnostics only (battery: normal)
#
# KNOWN LIMITATIONS
#   - On the "nvidia-panel" route Firefox only survives with software WebRender (heavy sites
#     get very slow). Hardware WebRender on nouveau/Kepler hits the [PTE] crashes below. A
#     reclocked nouveau (./nouveau-reclock.nix) might behave better; not verified.
#
# KNOWN KERNEL / DRIVER QUIRKS
#   - Known cursor bug: when the NVIDIA GPU drives the panel (after macOS), a ghost cursor can
#     appear at login. Fix: move your cursor off the screen, then log in.
#   - Wi-Fi: if it ever fails to return after a long sleep, try an unload/reload hook for "wl"
#     around suspend (not needed so far).
#   - Reading logs: kernel messages from the suspend sequence reach the journal only after wake,
#     so they carry the WAKE-UP timestamp. A gap between "Freezing user space processes" and
#     "completed" is just the time the lid was closed.
#   - Harmless: libinput "Lid Switch: client bug: event processing lagging behind" after resume;
#     nouveau "devinit: 0x0000644c[0]: script needs OR link" on every resume.
#   - Two render nodes exist (renderD128 = Intel, renderD129 = nouveau). Per-app GPU choice:
#     DRI_PRIME=pci-0000_00_02_0 (Intel) or DRI_PRIME=pci-0000_01_00_0 (nouveau).
#
# REFERENCES
#   Arch Wiki "MacBookPro10,x": https://wiki.archlinux.org/title/MacBookPro10,x
#   Arch Wiki "Backlight" (notes the Linux 6.1 acpi_backlight change)
#   mutter docs, doc/multi-gpu.md (primary GPU selection, copy modes)
#
# =============================================================================
# BACKGROUND (bottom of the header on purpose)
# =============================================================================
#
# WHY nouveau MUST LOAD
#   An early version blacklisted nouveau and tried "Intel only". That failed because with the
#   panel on the NVIDIA GPU, nothing real drove the screen (only the EFI framebuffer), GNOME saw
#   an "Unknown" output as an external monitor and kept a lid-switch inhibitor forever, and no
#   driver could re-init the GPU after S3. Letting nouveau load fixed lid, brightness (F1/F2) and
#   wake together. Later the Intel GPU became able to drive the panel instead (./igd-panel.nix).
#
# POWER (see ./power-tlp.nix)
#   TLP replaces power-profiles-daemon; tlp-pd keeps GNOME's "Power Mode" switch working. Turbo is
#   off in Balanced/Power Saver because the laptop ran warmer with it on. The 80% charge cap is done
#   by a userspace tool writing the Apple SMC BCLM/BFCL keys (verified: `sudo macbook-charge-limit
#   read` -> BCLM=80 BFCL=80). The CPU governor is left alone (intel_pstate passive mode).
#
# GPU PERFORMANCE NOTES (glmark2-wayland, 800x600, Mesa 26.2.3)
#   nouveau unclocked 927 | Intel HD 4000 1110 | reclocked nouveau on battery 1150, on AC 1845.
#   nouveau cannot reclock Kepler automatically, only manually (./nouveau-reclock.nix); the pstate
#   is fixed, so a high pstate means heat all the time.
#
# SOFTWARE RENDERING WORKAROUNDS (mbp.softwareRendering.*)
#   nouveau on Kepler intermittently kills GPU channels with page faults ("[PTE]"), crashing
#   Firefox and Qt Quick apps. Workaround: render on the CPU. ./routes.nix turns them on only when
#   nouveau drives the panel. Firefox: policy gfx.webrender.software (heavy sites get very slow;
#   needs programs.firefox.enable). Qt: QT_QUICK_BACKEND / QSG_RHI_BACKEND = software. Sessions
#   pick up Qt variables after re-login; Firefox picks up the policy on restart.
#
# BATTERY
#   The profile assumes a battery is installed, so the no-battery hack (BD_PROCHOT clear, turbo
#   lock) is OFF. It lives in ./no-battery.nix; if your MacBook runs without a battery, set
#   mbp.noBattery.enable = true. The "msr" module stays loaded for diagnostics.
# =============================================================================

{ config, lib, pkgs, ... }:

let
  swCfg = config.mbp.softwareRendering;
in
{
  imports = [ ./no-battery.nix ./power-tlp.nix ./nouveau-reclock.nix ./igd-panel.nix ./routes.nix ];

  options.mbp = {
    # Software-rendering workarounds for nouveau/Kepler GPU page-fault ([PTE]) channel crashes.
    # Independent switches, because they cost very different amounts of performance.
    # ./routes.nix sets them (lib.mkDefault) from whether nouveau drives the panel.
    softwareRendering.firefox.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Force Firefox WebRender onto the CPU (SWGL) through a locked enterprise policy
        (gfx.webrender.software). Avoids the [PTE] crashes but makes heavy sites (e.g.
        gemini.google.com) very slow. Set to false for hardware WebRender.
      '';
    };

    softwareRendering.qt.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Force Qt Quick / QML apps (e.g. rpi-imager) to the software scene-graph backend
        (QT_QUICK_BACKEND / QSG_RHI_BACKEND = software), bypassing nouveau's OpenGL.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # ---------------------------------------------------------------------------
      # Feature switches
      # ---------------------------------------------------------------------------
      # Assumes a battery is installed, so the no-battery hack (./no-battery.nix) is OFF.
      # If your MacBook runs without a battery:  mbp.noBattery.enable = true;
      mbp.noBattery.enable = lib.mkDefault false;

      # Reclock the NVIDIA GPU (nouveau pstate) + NVK Vulkan. EXPERIMENTAL, default off; read
      # ./nouveau-reclock.nix first (it runs the GPU hotter). igdPanel requires it OFF; for reclock
      # mode set mbp.panelGpu = "nvidia" (or mbp.igdPanel.enable = false), see ./routes.nix.
      mbp.nouveauReclock.enable = lib.mkDefault false;

      # nouveau.runpm=1: suspend-safe but saved no power (24-25 W) and makes vgaswitcheroo ON/OFF
      # no-ops, so it cannot be combined with isolateNvidia. See ./igd-panel.nix.
      mbp.igdPanel.runtimePm.enable = lib.mkDefault false;

      # Route-dependent settings (igdPanel, isolateNvidia, softwareRendering.*, GSK_RENDERER,
      # WGPU_BACKEND) are NOT here: ./routes.nix sets them from mbp.panelGpu.

      # ---------------------------------------------------------------------------
      # Kernel
      # ---------------------------------------------------------------------------

      # Newest kernel. The reason is the out-of-tree Broadcom "wl" driver (see the
      # Wi-Fi section): nixpkgs patches it to keep building against new kernels, see
      # https://github.com/NixOS/nixpkgs/blob/master/pkgs/os-specific/linux/broadcom-sta/default.nix
      # TRADE-OFF: with nixos-unstable this is a moving target. If a system update
      # ever fails to build broadcom_sta or breaks Wi-Fi, fall back to the default kernel or
      # an LTS in your own configuration: boot.kernelPackages = pkgs.linuxPackages;
      # (this is a lib.mkDefault, so a plain assignment wins).
      boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

      boot.kernelParams = [
        # Apple keyboard Fn behaviour (hid_apple module).
        #   0 = Fn key disabled
        #   1 = media keys first (Mac default: F1/F2 brightness, F5/F6 keyboard
        #       backlight, F10-F12 volume; Fn+Fx gives real F1-F12)
        #   2 = F1-F12 first (Fn+Fx gives the media keys)
        # Change at runtime, no reboot needed:
        #   echo 2 | sudo tee /sys/module/hid_apple/parameters/fnmode
        "hid_apple.fnmode=1"

        # NOTE: no "acpi_backlight=native", no "nouveau.modeset=0" and no
        # mem_sleep_default on purpose. See "THE KEY FACT" at the top.
      ];

      # ---------------------------------------------------------------------------
      # Wi-Fi: Broadcom (proprietary "wl" driver)
      # ---------------------------------------------------------------------------
      # The chip is a Broadcom part (probably BCM4360; verify with
      # `lspci -nnk | grep -A3 Network`; the interface appears as wlp4s0). It needs
      # the proprietary "wl" driver (package broadcom_sta).

      # Keep the open-source Broadcom drivers (and their bus drivers) away from the
      # chip so they never bind it before "wl" does.
      # NOTE: nouveau is intentionally NOT in this list.
      boot.blacklistedKernelModules = [
        "b43"
        "bcma"
        "ssb"
        "brcmfmac"
        "brcmsmac"
      ];

      boot.kernelModules = [
        "msr" # Kept loaded on purpose even with the battery installed: exposes
              # /dev/cpu/*/msr so `rdmsr` works for diagnostics, and
              # ./no-battery.nix needs it if that mode is enabled.
        "wl"  # The proprietary Broadcom Wi-Fi driver.
      ];

      # Redistributable firmware blobs. Among other things, CPU microcode updates
      # are controlled by this. Harmless to keep.
      hardware.enableRedistributableFirmware = lib.mkDefault true;

      # broadcom_sta is unfree, and nixpkgs marks it insecure (known vulnerabilities
      # in the driver). We accept that risk knowingly because this card has no free
      # driver. Using `.name` of the current kernel's package makes the permit follow
      # kernel updates automatically instead of needing a manual edit each time.
      # To remove the risk: replace the card or use a USB Wi-Fi adapter with an
      # open-source driver.
      nixpkgs.config.allowUnfree = true;
      nixpkgs.config.permittedInsecurePackages = [
        config.boot.kernelPackages.broadcom_sta.name
      ];
      boot.extraModulePackages = [ config.boot.kernelPackages.broadcom_sta ];

      # ---------------------------------------------------------------------------
      # CPU / power
      # ---------------------------------------------------------------------------
      # Power profiles are handled by TLP (./power-tlp.nix). power-profiles-daemon is forced off
      # there because the two cannot run together; tlp-pd provides the same D-Bus API, so GNOME's
      # "Power Mode" switch keeps working. If TLP is switched off (mbp.tlp.enable = false),
      # GNOME's default (PPD on) applies again; no-battery mode forces PPD off by itself.

      # Intel thermal daemon: safety net for heat (the Intel GPU shares the CPU's thermal budget).
      services.thermald.enable = lib.mkDefault true;
    }

    # -----------------------------------------------------------------------------
    # SOFTWARE RENDERING WORKAROUNDS (see "SOFTWARE RENDERING WORKAROUNDS" at the top)
    # -----------------------------------------------------------------------------

    # Qt Quick / QML (e.g. rpi-imager): bypass nouveau's OpenGL scene graph, rasterize on CPU.
    (lib.mkIf swCfg.qt.enable {
      environment.sessionVariables = {
        QT_QUICK_BACKEND = "software";
        QSG_RHI_BACKEND = "software";
      };
    })

    # Firefox: bypass hardware WebRender (nouveau/Kepler [PTE] channel crashes); rasterize on
    # the CPU (SWGL). "locked" means about:config cannot override it; to test hardware WebRender
    # without a rebuild, change Status to "default" temporarily, or set firefox.enable = false.
    (lib.mkIf swCfg.firefox.enable {
      programs.firefox.policies.Preferences."gfx.webrender.software" = {
        Value = true;
        Status = "locked";
      };
    })
  ];
}
