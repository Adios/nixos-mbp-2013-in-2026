# =============================================================================
# hardware/routes.nix  --  everything that depends on WHICH GPU drives the panel
# =============================================================================
#
# ONE option, mbp.panelGpu, decides every setting that only makes sense for one kind of boot:
# the igd-panel switches, software rendering, GSK_RENDERER and WGPU_BACKEND.
#
# THE THREE BOOT ENTRIES
#   normal entry     panel on Intel, NVIDIA GPU isolated and powered OFF   ~14-16 W
#   "desk"           panel on Intel, NVIDIA GPU ON for external monitors   ~24-25 W
#                    (specialisation defined in ./igd-panel.nix, isolation off)
#   "nvidia-panel"   panel on the NVIDIA GPU (plain nouveau setup),
#                    with all the nouveau workarounds                       ~24-25 W
#                    (specialisation defined in this file)
#
# WHAT EACH ENTRY SETS (this table is the whole logic below)
#                          normal      desk        nvidia-panel
#   igdPanel (arming)      on          on          OFF
#   isolateNvidia (OFF)    on          off         off
#   software Firefox/Qt    off         off         ON
#   GSK_RENDERER=gl        unset       unset       gl
#   WGPU_BACKEND=gl        unset       gl          gl
#   dgpu-status command    yes         yes         yes  (igd-panel.nix installs it always)
#   dgpu-arm command       yes         yes         yes  (igd-panel.nix installs it always)
#   (desk keeps WGPU_BACKEND=gl because nouveau's NVK Vulkan driver is visible there;
#    in the normal entry the Vulkan loader hides it, see igd-panel.nix.)
#
# HOW IT IS DERIVED (so a single setting can still be overridden)
#   "nouveau drives the panel" is simply `!mbp.igdPanel.enable`. That is true in the
#   "nvidia-panel" entry (panelGpu = "nvidia") and also whenever igdPanel is switched off by
#   hand (e.g. for mbp.nouveauReclock). The software-rendering switches and the two renderer
#   switches below follow it. Every route value is a lib.mkDefault, so a plain assignment
#   anywhere wins, for example:
#     mbp.glRenderers.wgpu.enable = true;                       # all routes
#     specialisation.nvidia-panel.configuration.mbp.softwareRendering.firefox.enable = false;
#   WGPU_BACKEND is also on whenever the NVIDIA GPU is not isolated (desk), because NVK is
#   visible to wgpu there.
#
# IMPORTANT: THE FIRMWARE CHOOSES THE PANEL GPU BEFORE LINUX STARTS
#   Whether the panel is on Intel or NVIDIA is decided by the EFI variable armed at the
#   previous shutdown (see igd-panel.nix). A boot entry cannot change it: it only changes
#   the software configuration to fit. Consequences:
#     - After booting macOS (or right after the install) the variable is gone, so the next
#       Linux boot has the panel on the NVIDIA GPU. Pick the "nvidia-panel" entry: it has the
#       workarounds, and it does NOT arm the variable at shutdown, so the following boots stay
#       on the NVIDIA panel. (The normal entry also boots there, the isolation service leaves
#       the NVIDIA GPU alone, but without the workarounds: Firefox can hit the nouveau [PTE]
#       crashes.)
#     - Back to the Intel panel: from ANY entry (also "nvidia-panel") run `sudo dgpu-arm`,
#       reboot.
#     - Booting "nvidia-panel" while the panel is actually on Intel (variable was armed) is
#       NOT free: the variable is consumed by that boot and this entry does not re-arm it at
#       shutdown, so the NEXT boot comes up on the NVIDIA panel. Recover as above (`sudo
#       dgpu-arm`, reboot). On top of that the workarounds cost speed for that boot.
#       (If this bites often: let the entry keep igdPanel on, so it still arms at shutdown
#       when, and only when, i915 drives the panel; then set nouveauPanel from panelGpu
#       instead of from igdPanel.enable.)
#   `dgpu-status` works in every entry and shows which GPU drives the panel.
#
# WHY THESE SETTINGS ARE ROUTE-DEPENDENT
#   GSK_RENDERER=gl   After S3 resume, GTK4 apps (e.g. gnome-terminal) drew garbled glyph
#                     textures because of stale GPU cache state under nouveau. Only apps
#                     rendered on nouveau are affected. Fallbacks if "gl" is ever removed
#                     upstream: "ngl" (new GL) or "cairo" (CPU).
#   WGPU_BACKEND=gl   COSMIC apps (iced/libcosmic) default to Vulkan. Kepler's experimental
#                     NVK driver fails on glyph atlas textures, so all text rendered as
#                     solid blocks. Verified: not needed on the Intel route (COSMIC apps
#                     render fine on the Intel GPU without it).
#   software Firefox  Avoids the nouveau [PTE] channel crashes (WebRender on nouveau). Makes
#                     heavy sites (e.g. gemini.google.com) very slow, so only when needed.
#   software Qt       Same crashes for Qt Quick apps (e.g. rpi-imager).
#
# RECLOCK MODE (mbp.nouveauReclock.enable = true) needs nouveau on the panel and igdPanel off.
#   Either set mbp.panelGpu = "nvidia"; (then the table above applies with every workaround on
#   and no extra boot entry, because nothing is isolated), or set mbp.igdPanel.enable = false;
#   directly. igd-panel.nix asserts the combination.
#
# TO CHANGE A SETTING FOR ONE ROUTE: edit the table in the `config` block below, or override
#   the option (see HOW IT IS DERIVED).
# TO DROP THE EXTRA BOOT ENTRY (it adds evaluation/build time):
#   mbp.nvidiaPanelSpecialisation = false;
# =============================================================================

{ config, lib, ... }:

let
  # Nouveau drives the panel: the "nvidia-panel" entry, or igdPanel switched off by hand.
  nouveauPanel = !config.mbp.igdPanel.enable;
  isolated = config.mbp.igdPanel.isolateNvidia.enable;
  intelRoute = config.mbp.panelGpu == "intel";
in
{
  options.mbp = {
    panelGpu = lib.mkOption {
      type = lib.types.enum [ "intel" "nvidia" ];
      default = "intel";
      description = ''
        Which GPU is assumed to drive the internal panel in this configuration. "intel" is
        the normal setup (and the "desk" entry). "nvidia" turns the nouveau workarounds on
        and the Intel-panel machinery (arming, isolation) off; the "nvidia-panel" boot entry
        sets it. See the header of hosts/mbp/routes.nix. The firmware, not this option,
        decides where the panel really is.
      '';
    };

    nvidiaPanelSpecialisation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build the extra boot entry "nvidia-panel" (panelGpu = "nvidia"). It only exists on
        top of the normal configuration (never inside "desk" or itself).
      '';
    };

    glRenderers.gsk.enable = lib.mkOption {
      type = lib.types.bool;
      default = nouveauPanel;
      defaultText = lib.literalExpression "!config.mbp.igdPanel.enable";
      description = ''
        Set GSK_RENDERER=gl session-wide (GTK4 apps drew garbled glyphs after resume while
        rendering on nouveau). Default: on when nouveau drives the panel.
      '';
    };

    glRenderers.wgpu.enable = lib.mkOption {
      type = lib.types.bool;
      default = nouveauPanel || !isolated;
      defaultText = lib.literalExpression "!config.mbp.igdPanel.enable || !config.mbp.igdPanel.isolateNvidia.enable";
      description = ''
        Set WGPU_BACKEND=gl session-wide (COSMIC/wgpu apps render text as tofu on nouveau's
        NVK Vulkan driver). Default: on whenever nouveau is reachable, i.e. nouveau drives the
        panel or the NVIDIA GPU is not isolated ("desk").
      '';
    };
  };

  config = lib.mkMerge [
    # --- the table -----------------------------------------------------------------------
    {
      mbp.igdPanel.enable = lib.mkDefault intelRoute;
      mbp.igdPanel.isolateNvidia.enable = lib.mkDefault intelRoute; # "desk" forces false (igd-panel.nix)

      mbp.softwareRendering.firefox.enable = lib.mkDefault nouveauPanel;
      mbp.softwareRendering.qt.enable = lib.mkDefault nouveauPanel;

      environment.sessionVariables = lib.mkMerge [
        (lib.mkIf config.mbp.glRenderers.gsk.enable { GSK_RENDERER = "gl"; })
        (lib.mkIf config.mbp.glRenderers.wgpu.enable { WGPU_BACKEND = "gl"; })
      ];
    }

    # --- the extra boot entry ------------------------------------------------------------
    # Only defined on the normal configuration (Intel route, igdPanel on, isolation on):
    # "desk" (isolation off) and the entry itself (panelGpu = "nvidia") fail this condition,
    # so specialisations never nest.
    (lib.mkIf (config.mbp.nvidiaPanelSpecialisation && intelRoute && config.mbp.igdPanel.enable && isolated) {
      specialisation.nvidia-panel.configuration = {
        system.nixos.tags = [ "nvidia-panel" ];
        mbp.panelGpu = lib.mkForce "nvidia";
      };
    })
  ];
}
