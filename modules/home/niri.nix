# =============================================================================
# modules/home/niri.nix  --  the niri session's user side (config.kdl + companion tools)
# =============================================================================
#
# SPLIT OF RESPONSIBILITIES
#   modules/nixos/niri.nix  system side: programs.niri (binary, session entry, portals,
#                           keyring), PAM service for swaylock, xwayland-satellite, udev.
#   this file               user side: ~/.config/niri/config.kdl and the companion tools.
#   mbp-niri-gpu.nix        the GPU rules for this MacBook (render on Intel, ignore NVIDIA).
#
# WHY THE COMPANION TOOLS ARE PLAIN systemd USER UNITS, NOT services.mako / services.swayidle
#   GNOME is kept on this machine. The Home Manager service modules start their tool in every
#   graphical session, which would fight gnome-shell (notifications, idle, polkit agent). Here
#   each unit is WantedBy=niri.service, so it only exists in the niri session. The tools'
#   config files are still written declaratively.
#
# WHAT RUNS IN THE NIRI SESSION
#   waybar (bar + tray), mako (notifications), swayidle (lock / screen off / suspend),
#   swaybg (wallpaper), polkit-gnome agent. Started by xdg-autostart: gnome-keyring.
#   Launcher: fuzzel. Lock: swaylock. Terminal: Alacritty.
#   No input method is configured; add your own (fcitx5, ibus) if you type CJK.
#
# WHERE TO CHANGE THINGS
#   Scale / text size / cursor / key repeat / touchpad ... my.desktop.* (host's home.nix).
#   Fonts of the bar etc.                                  my.desktop.uiFont.* (and textScale).
#   Output names, GPU device hints, extra KDL              my.niri.* (see mbp-niri-gpu.nix).
#   Key bindings, layout, animations                       the `configText` below.
#   Idle timeouts                                          the swayidle unit below.
#   Colours                                                my.niri.theme: "solarized-dark"
#                                                          (default) or "solarized-light".
#   Apply: `sudo nixos-rebuild switch --flake .`; niri reloads config.kdl by itself.
#   Syntax check: `niri validate` runs at build time (my.niri.validate), so a typo fails the
#   build instead of silently falling back to niri's defaults.
#
# APPLE KEYBOARD
#   hardware/hardware-fixes.nix sets hid_apple.fnmode=1, so F1..F12 are the media keys
#   (brightness, keyboard backlight, volume, ...). The binds below match that.
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.my.niri;
  desk = config.my.desktop;
  ui = desk.uiFont;

  # UI font size after "Large Text".
  uiSize = toString (ui.size * desk.textScale);

  # Colours: Solarized (https://ethanschoonover.com/solarized/), blue accent. Pick the variant
  # with my.niri.theme ("solarized-dark" or "solarized-light"). onAccent is the text colour that
  # sits on top of the accent (selected row, active workspace).
  palettes = {
    solarized-dark = {
      bg = "#073642"; # base02: bar, launcher, notifications
      fg = "#93a1a1"; # base1: body text
      dim = "#586e75"; # base01
      accent = "#268bd2"; # blue
      accentLight = "#cb4b16"; # orange: fuzzel match highlight
      warn = "#b58900"; # yellow
      crit = "#dc322f"; # red
      wall = "#002b36"; # base03: swaylock / wallpaper fallback
      onAccent = "#fdf6e3"; # base3
    };

    solarized-light = {
      bg = "#eee8d5"; # base2: bar, launcher, notifications
      fg = "#586e75"; # base01: body text
      dim = "#93a1a1"; # base1
      accent = "#268bd2"; # blue
      accentLight = "#cb4b16"; # orange: fuzzel match highlight
      warn = "#b58900"; # yellow
      crit = "#dc322f"; # red
      wall = "#fdf6e3"; # base3: swaylock / wallpaper fallback
      onAccent = "#fdf6e3"; # base3
    };
  };
  c = palettes.${cfg.theme};
  hex = s: lib.removePrefix "#" s;

  # Programs, as absolute store paths (the user manager's PATH is minimal).
  bin = {
    alacritty = "${config.programs.alacritty.package}/bin/alacritty";
    fuzzel = "${pkgs.fuzzel}/bin/fuzzel";
    swaylock = "${pkgs.swaylock}/bin/swaylock";
    waybar = "${pkgs.waybar}/bin/waybar";
    mako = "${pkgs.mako}/bin/mako";
    swayidle = "${pkgs.swayidle}/bin/swayidle";
    swaybg = "${pkgs.swaybg}/bin/swaybg";
    niri = "${pkgs.niri}/bin/niri";
    wpctl = "${pkgs.wireplumber}/bin/wpctl";
    brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
    playerctl = "${pkgs.playerctl}/bin/playerctl";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    pavucontrol = "${pkgs.pavucontrol}/bin/pavucontrol";
    polkitAgent = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
  };

  # Random wallpaper: a random picture (jpg/png) from this folder every wallpaperInterval seconds.
  # No folder or no pictures: a plain background in the theme colour.
  wallpaperDir = "${config.home.homeDirectory}/Pictures/Wallpapers";
  wallpaperInterval = 3600; # seconds

  wallpaperLoop = pkgs.writeShellScript "niri-wallpaper" ''
    pid=
    trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; exit 0' TERM INT
    while true; do
      img=$(${pkgs.findutils}/bin/find -L ${lib.escapeShellArg wallpaperDir} -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null \
        | ${pkgs.coreutils}/bin/shuf -n 1)
      if [ -n "$img" ]; then
        ${bin.swaybg} -m fill -i "$img" -c ${hex c.wall} &
      else
        ${bin.swaybg} -c ${hex c.wall} &
      fi
      new=$!
      # Kill the previous swaybg only after the new one is up, so there is no flash.
      [ -n "$pid" ] && kill "$pid" 2>/dev/null
      pid=$new
      ${pkgs.coreutils}/bin/sleep ${toString wallpaperInterval} &
      wait $!
    done
  '';

  # key repeat: GNOME stores the interval in ms, niri wants a rate in Hz.
  repeatRate = builtins.floor (1000.0 / (desk.keyboard.repeatInterval + 0.0) + 0.5);

  touchpadLines = lib.concatStringsSep "\n        " (
    lib.optional desk.touchpad.tapToClick "tap"
    ++ lib.optional desk.touchpad.naturalScroll "natural-scroll"
    ++ [
      "dwt"
      "accel-speed ${toString desk.touchpad.speed}"
    ]
  );

  outputBlocks = lib.concatMapStrings (o: ''
    output "${o}" {
        scale ${toString desk.scale}
    }
  '') cfg.outputs;

  debugBlock =
    lib.optionalString (cfg.renderDrmDevice != null || cfg.ignoreDrmDevices != [ ]) ''
      debug {
      ${lib.optionalString (cfg.renderDrmDevice != null) ''
          render-drm-device "${cfg.renderDrmDevice}"
      ''}${lib.concatMapStrings (d: ''
          ignore-drm-device "${d}"
      '') cfg.ignoreDrmDevices}}
    '';

  configText = ''
    // Generated by Home Manager from modules/home/niri.nix. Edit the Nix, not this file.

    input {
        keyboard {
            xkb {
                layout "us"
            }
            repeat-delay ${toString desk.keyboard.delay}
            repeat-rate ${toString repeatRate}
        }
        touchpad {
            ${touchpadLines}
        }
    }

    // --- Display: same scale as GNOME (my.desktop.scale) -------------------------------
    // Both connector names are listed because the panel is eDP-1 on the Intel route and may be
    // eDP-2 on the nvidia-panel route. Names that do not exist are ignored.
    ${outputBlocks}
    // "Larger text" has no niri setting. GTK apps get it from dconf (text-scaling-factor);
    // see my.desktop.textScale for the apps that are scaled in Nix.

    cursor {
        xcursor-theme "Adwaita"
        xcursor-size ${toString desk.cursorSize}
    }

    prefer-no-csd

    // GNOME has animations off (enable-animations = false); keep it consistent.
    animations {
        off
    }

    hotkey-overlay {
        skip-at-startup
    }

    screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

    layout {
        gaps 12
        center-focused-column "never"
        preset-column-widths {
            proportion 0.33333
            proportion 0.5
            proportion 0.66667
        }
        default-column-width { proportion 0.5; }
        focus-ring {
            width 3
            active-color "${c.accent}"
            inactive-color "${c.dim}"
        }
        border {
            off
        }
    }

    window-rule {
        geometry-corner-radius 12
        clip-to-geometry true
    }

    ${debugBlock}
    binds {
        Mod+Shift+Slash { show-hotkey-overlay; }

        // --- Programs ---------------------------------------------------------------
        Mod+Return { spawn "${bin.alacritty}"; }
        Mod+T { spawn "${bin.alacritty}"; }
        Mod+D { spawn "${bin.fuzzel}"; }
        Mod+B { spawn "firefox"; }
        Mod+E { spawn "nautilus"; }
        Mod+Alt+L { spawn "${bin.swaylock}" "-f"; }

        // --- Windows and columns ----------------------------------------------------
        Mod+Q { close-window; }

        Mod+Left  { focus-column-left; }
        Mod+Down  { focus-window-down; }
        Mod+Up    { focus-window-up; }
        Mod+Right { focus-column-right; }
        Mod+H     { focus-column-left; }
        Mod+J     { focus-window-down; }
        Mod+K     { focus-window-up; }
        Mod+L     { focus-column-right; }

        Mod+Ctrl+Left  { move-column-left; }
        Mod+Ctrl+Down  { move-window-down; }
        Mod+Ctrl+Up    { move-window-up; }
        Mod+Ctrl+Right { move-column-right; }
        Mod+Ctrl+H     { move-column-left; }
        Mod+Ctrl+J     { move-window-down; }
        Mod+Ctrl+K     { move-window-up; }
        Mod+Ctrl+L     { move-column-right; }

        Mod+Home { focus-column-first; }
        Mod+End  { focus-column-last; }

        Mod+BracketLeft  { consume-or-expel-window-left; }
        Mod+BracketRight { consume-or-expel-window-right; }
        Mod+Comma  { consume-window-into-column; }
        Mod+Period { expel-window-from-column; }

        Mod+R { switch-preset-column-width; }
        Mod+Shift+R { switch-preset-window-height; }
        Mod+Ctrl+R { reset-window-height; }
        Mod+F { maximize-column; }
        Mod+Shift+F { fullscreen-window; }
        Mod+C { center-column; }
        Mod+Minus { set-column-width "-10%"; }
        Mod+Equal { set-column-width "+10%"; }
        Mod+Shift+Minus { set-window-height "-10%"; }
        Mod+Shift+Equal { set-window-height "+10%"; }
        Mod+V { toggle-window-floating; }
        Mod+Shift+V { switch-focus-between-floating-and-tiling; }
        Mod+W { toggle-column-tabbed-display; }

        // --- Workspaces -------------------------------------------------------------
        Mod+Page_Down { focus-workspace-down; }
        Mod+Page_Up   { focus-workspace-up; }
        Mod+U { focus-workspace-down; }
        Mod+I { focus-workspace-up; }
        Mod+Ctrl+Page_Down { move-column-to-workspace-down; }
        Mod+Ctrl+Page_Up   { move-column-to-workspace-up; }
        Mod+Ctrl+U { move-column-to-workspace-down; }
        Mod+Ctrl+I { move-column-to-workspace-up; }

        Mod+1 { focus-workspace 1; }
        Mod+2 { focus-workspace 2; }
        Mod+3 { focus-workspace 3; }
        Mod+4 { focus-workspace 4; }
        Mod+5 { focus-workspace 5; }
        Mod+6 { focus-workspace 6; }
        Mod+7 { focus-workspace 7; }
        Mod+8 { focus-workspace 8; }
        Mod+9 { focus-workspace 9; }
        Mod+Ctrl+1 { move-column-to-workspace 1; }
        Mod+Ctrl+2 { move-column-to-workspace 2; }
        Mod+Ctrl+3 { move-column-to-workspace 3; }
        Mod+Ctrl+4 { move-column-to-workspace 4; }
        Mod+Ctrl+5 { move-column-to-workspace 5; }
        Mod+Ctrl+6 { move-column-to-workspace 6; }
        Mod+Ctrl+7 { move-column-to-workspace 7; }
        Mod+Ctrl+8 { move-column-to-workspace 8; }
        Mod+Ctrl+9 { move-column-to-workspace 9; }

        Mod+WheelScrollDown cooldown-ms=150 { focus-workspace-down; }
        Mod+WheelScrollUp   cooldown-ms=150 { focus-workspace-up; }
        Mod+WheelScrollRight { focus-column-right; }
        Mod+WheelScrollLeft  { focus-column-left; }

        Mod+O repeat=false { toggle-overview; }

        // --- Screenshots (saved to screenshot-path and copied to the clipboard) -------
        Mod+Shift+S { screenshot; }
        Mod+Shift+3 { screenshot-screen; }
        Mod+Shift+4 { screenshot-window; }

        // --- Apple keyboard media keys (hid_apple.fnmode=1: F1..F12 are the media keys) ---
        XF86MonBrightnessUp   allow-when-locked=true { spawn "${bin.brightnessctl}" "set" "5%+"; }
        XF86MonBrightnessDown allow-when-locked=true { spawn "${bin.brightnessctl}" "set" "5%-"; }
        XF86KbdBrightnessUp   allow-when-locked=true { spawn "${bin.brightnessctl}" "--device=smc::kbd_backlight" "set" "10%+"; }
        XF86KbdBrightnessDown allow-when-locked=true { spawn "${bin.brightnessctl}" "--device=smc::kbd_backlight" "set" "10%-"; }
        XF86AudioRaiseVolume allow-when-locked=true { spawn "${bin.wpctl}" "set-volume" "-l" "1.0" "@DEFAULT_AUDIO_SINK@" "5%+"; }
        XF86AudioLowerVolume allow-when-locked=true { spawn "${bin.wpctl}" "set-volume" "-l" "1.0" "@DEFAULT_AUDIO_SINK@" "5%-"; }
        XF86AudioMute        allow-when-locked=true { spawn "${bin.wpctl}" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
        XF86AudioPlay allow-when-locked=true { spawn "${bin.playerctl}" "play-pause"; }
        XF86AudioNext allow-when-locked=true { spawn "${bin.playerctl}" "next"; }
        XF86AudioPrev allow-when-locked=true { spawn "${bin.playerctl}" "previous"; }

        // --- Session ----------------------------------------------------------------
        Mod+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }
        Mod+Shift+E { quit; }
        Mod+Shift+P { power-off-monitors; }
    }

    ${cfg.extraConfig}
  '';

  rawConfig = pkgs.writeText "niri-config.kdl" configText;

  # Fail the build, not the session, when the KDL is wrong.
  checkedConfig =
    pkgs.runCommand "niri-config-checked.kdl" { nativeBuildInputs = [ pkgs.niri ]; } ''
      niri validate --config ${rawConfig}
      cp ${rawConfig} $out
    '';

  # A user unit that only exists in the niri session (see the header).
  niriUnit = description: exec: extra: {
    Unit = {
      Description = description;
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = exec;
      Restart = "on-failure";
      RestartSec = 1;
    } // extra;
    Install.WantedBy = [ "niri.service" ];
  };
in
{
  imports = [
    ./desktop-scale.nix
    ./alacritty.nix
  ];

  options.my.niri = {
    theme = lib.mkOption {
      type = lib.types.enum [ "solarized-dark" "solarized-light" ];
      default = "solarized-dark";
      description = "Colour scheme of the niri session (bar, launcher, notifications, lock screen, focus ring).";
    };

    outputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "eDP-1" ];
      description = "Output connector names that get my.desktop.scale.";
    };

    renderDrmDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/dri/by-path/pci-0000:00:02.0-render";
      description = "niri `debug { render-drm-device }`: force the GPU niri renders on. null = niri decides.";
    };

    ignoreDrmDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "niri `debug { ignore-drm-device }` entries: GPUs niri must never open.";
    };

    validate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run `niri validate` on the generated config at build time.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra KDL appended to config.kdl (host-specific rules, outputs, ...).";
    };
  };

  config = {
    xdg.configFile."niri/config.kdl".source = if cfg.validate then checkedConfig else rawConfig;

    home.packages = with pkgs; [
      brightnessctl
      pavucontrol
      playerctl
      wl-clipboard
    ];

    # --- Launcher: fuzzel -----------------------------------------------------------
    programs.fuzzel = {
      enable = true;
      settings = {
        main = {
          font = "${ui.name}:size=${uiSize}";
          terminal = "${bin.alacritty} -e";
          width = 36;
          lines = 10;
        };
        colors = {
          background = "${hex c.bg}f2";
          text = "${hex c.fg}ff";
          match = "${hex c.accentLight}ff";
          selection = "${hex c.accent}ff";
          selection-text = "${hex c.onAccent}ff";
          border = "${hex c.accent}ff";
        };
        border = {
          width = 2;
          radius = 12;
        };
      };
    };

    # --- Lock screen: swaylock (PAM service is in modules/nixos/niri.nix) -----------
    programs.swaylock = {
      enable = true;
      settings = {
        color = hex c.wall;
        font = ui.name;
        indicator-radius = 100;
        show-failed-attempts = true;
      };
    };

    # --- Bar: waybar (text only: no icon font needed) -------------------------------
    programs.waybar = {
      enable = true;
      settings.mainBar = {
        layer = "top";
        position = "top";
        spacing = 4;
        modules-left = [ "niri/workspaces" "niri/window" ];
        modules-center = [ "clock" ];
        modules-right = [ "tray" "pulseaudio" "backlight" "network" "battery" ];

        "niri/workspaces".format = "{index}";
        "niri/window" = {
          format = "{title}";
          max-length = 60;
        };
        clock = {
          format = "{:%a %b %d  %I:%M %p}";
          tooltip-format = "{:%A, %B %d, %Y}";
        };
        pulseaudio = {
          format = "vol {volume}%";
          format-muted = "muted";
          on-click = bin.pavucontrol;
        };
        backlight.format = "bri {percent}%";
        network = {
          format-wifi = "{essid}";
          format-ethernet = "wired";
          format-disconnected = "offline";
          tooltip-format = "{ifname}: {ipaddr}";
          on-click = "${bin.alacritty} -e nmtui";
        };
        battery = {
          format = "bat {capacity}%";
          format-charging = "chg {capacity}%";
          states = {
            warning = 30;
            critical = 15;
          };
        };
        tray.spacing = 8;
      };
      style = ''
        * {
          font-family: "${ui.name}", "Noto Sans CJK JP", sans-serif;
          font-size: ${uiSize}pt;
          border: none;
          border-radius: 0;
          min-height: 0;
        }
        window#waybar {
          background: ${c.bg};
          color: ${c.fg};
        }
        #workspaces button {
          padding: 0 8px;
          color: ${c.dim};
          background: transparent;
        }
        #workspaces button.active {
          color: ${c.onAccent};
          background: ${c.accent};
        }
        #clock, #pulseaudio, #backlight, #network, #battery, #tray, #window {
          padding: 0 10px;
        }
        #battery.warning { color: ${c.warn}; }
        #battery.critical { color: ${c.crit}; }
        #network.disconnected, #pulseaudio.muted { color: ${c.dim}; }
      '';
    };

    # --- Notifications: mako --------------------------------------------------------
    xdg.configFile."mako/config".text = ''
      font=${ui.name} ${uiSize}
      background-color=${c.bg}
      text-color=${c.fg}
      border-color=${c.accent}
      border-size=2
      border-radius=12
      padding=12
      margin=12
      width=420
      default-timeout=7000

      [urgency=high]
      border-color=${c.crit}
      default-timeout=0
    '';

    # --- Session-scoped units -------------------------------------------------------
    systemd.user.services = {
      niri-waybar = niriUnit "Waybar (niri session)" bin.waybar {
        ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR2 $MAINPID";
      };

      niri-mako = niriUnit "Mako notifications (niri session)" bin.mako { };

      niri-swaybg = niriUnit "Wallpaper (niri session)" "${wallpaperLoop}" { };

      niri-polkit-agent = niriUnit "Polkit agent (niri session)" bin.polkitAgent { };

      # GNOME's own idle handling (screen blank / auto suspend) does not run in niri.
      # 5 min lock, 5.5 min screen off, 15 min suspend; also lock before any sleep.
      # (Lid close is left to logind on purpose, see hardware/hardware-fixes.nix.)
      niri-swayidle = niriUnit "Idle management (niri session)" (lib.concatStringsSep " " [
        "${bin.swayidle} -w"
        "timeout 300 '${bin.swaylock} -f'"
        "timeout 330 '${bin.niri} msg action power-off-monitors'"
        "resume '${bin.niri} msg action power-on-monitors'"
        "timeout 900 '${bin.systemctl} suspend'"
        "before-sleep '${bin.swaylock} -f'"
        "lock '${bin.swaylock} -f'"
      ]) { };
    };
  };
}
