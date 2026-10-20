# NixOS on the MacBook Pro 15" Retina, Early 2013 (MacBookPro10,1)

A working NixOS configuration for the **MacBook Pro 15-inch Retina, Early 2013** (`MacBookPro10,1`,
Intel HD 4000 + NVIDIA GT 650M behind an Apple gmux), written for people who want to run NixOS on
this machine in 2026 and do not want to rediscover which GPU setup actually works.

It contains:

- a **hardware profile** you can import into your own flake (`hardware/`), and
- a small **example host** with GNOME and niri sessions plus an **installer script** that sets
  it up next to macOS (`hosts/mbp/`, `scripts/install.sh`), if you would rather start from
  something that works.

![A MacBook Pro 15" Retina, Early 2013, running niri on NixOS in 2026](PASTE-PHOTO-URL-HERE)

> **Read this first**
>
> 1. **This extracted repository itself was never tested.** It was cut out of the author's private
>    config in October 2026 with the help of Claude Sonnet 5.5; nobody has built or installed it
>    in this form. What *is* real: the settings, the theory and the findings. The author runs the
>    original configuration every day on this exact machine (MacBookPro10,1, i7-3740QM, 16 GB,
>    macOS 15 via OCLP). Expect small extraction slips (a typo, a missing import) and fix them;
>    the comments at the top of the `.nix` files hold the findings, which are the valuable part.
> 2. **Wi-Fi is the fragile part.** It works with the `flake.lock` shipped here. Read
>    [Wi-Fi: think before updating](#3-wi-fi-it-works-on-the-shipped-flakelock-think-before-updating)
>    before you update anything.
> 3. **Not maintained.** Issues and pull requests may go unanswered; fork freely.

**Reproducible:** `flake.lock` is the author's real lock from 15 October 2026 (the revisions Wi-Fi is known to work on, see [below](#3-wi-fi-it-works-on-the-shipped-flakelock-think-before-updating)). Keep it until you have a reason to update.

## TL;DR

| You are... | Do this |
|---|---|
| installing fresh, dual boot with macOS | [Install with the script](#a-fresh-install-next-to-macos) |
| already on NixOS (flakes) | [Import the module](#b-use-it-from-your-own-flake), one line, defaults are the recommended setup |
| just curious / on another model | Read the headers of `hardware/igd-panel.nix` and `hardware/hardware-fixes.nix` |

**The recommended setup is the default.** After the install, boot the normal entry and you get: the
Intel GPU drives the panel, the NVIDIA GPU is powered off, Wayland (GNOME or niri), about
14-16 W idle instead of 24-25 W, Wi-Fi, working lid suspend and brightness keys, TLP power
profiles and an 80% battery charge cap.
Two habits come with it: [arm the Intel panel with `sudo dgpu-arm`](#1-arming-the-intel-panel-sudo-dgpu-arm)
after the install and after every macOS boot, and the [80% cap](#2-the-battery-is-capped-at-80) is
survives macOS boots and is only lifted by a PRAM/SMC reset.

## Things you must know

### 1. Arming the Intel panel: `sudo dgpu-arm`

The Apple firmware decides which GPU drives the screen **before Linux starts**, from an EFI
variable. If that variable is not set, the panel is on the NVIDIA GPU (hot, 24-25 W, nouveau
crashes) and the NVIDIA GPU is not powered off. **Arming** sets the variable; it takes effect on
the **next boot**.

**How to arm** (works from every boot entry, including `nvidia-panel`):

```sh
sudo dgpu-arm
sudo reboot
dgpu-status        # after the reboot: want "panel: i915" and the NVIDIA GPU "Off"
```

**When you have to arm by hand:**

| Situation | Why |
|---|---|
| **Right after the install**, first boot | nothing has armed it yet |
| **After every boot into macOS** | macOS ignores/overwrites the variable |
| **After an NVRAM/PRAM reset** (`Cmd+Option+P+R`), including the black-screen recovery | the reset clears it |
| After you booted `nvidia-panel` while the panel was on Intel | that boot consumes the variable and that entry does not re-arm it |

**When you do NOT have to:** normal Linux use. Every shutdown/reboot from the normal or `desk`
entry arms it automatically, but only if the Intel GPU is driving the panel at that moment. So a
broken boot can never re-arm itself. (`mbp.igdPanel.armEveryBoot = true` arms at every boot, even
from a NVIDIA-panel boot, which suits a Linux-only machine.)

**How you notice that you need it:** `dgpu-status` says the panel is on nouveau/NVIDIA, the
machine runs hot with the fan up, or you just came back from macOS. The variable cannot be read
back from Linux, so judge by what the next boot does. Which entry to pick in the meantime is
explained in [Boot entries](#boot-entries-and-the-macos-round-trip).

### 2. The battery is capped at 80%

The cap is on by default and needs no action: `macbook-charge-limit` writes it to the Apple SMC
at every boot and again after resume, and charging stops at about 80%. The limit lives in the
firmware (SMC), not in Linux, so it **survives reboots and round trips through macOS**: boot
macOS, boot NixOS again, and the cap is still there. Only a reset removes it. That suits an old
Mac whose battery you want to keep healthy.

- **A firmware reset lifts the cap:** an NVRAM/PRAM reset (`Cmd+Option+P+R`) and/or an SMC reset.
  The author did both and the cap was gone; it is not known which of the two does it. Linux puts
  the cap back the next time it boots; to re-apply it right away without rebooting:
  `sudo systemctl restart macbook-charge-limit`.
- Check: `sudo macbook-charge-limit read` should print `BCLM=80 BFCL=80`.
- Full charge for a trip: `sudo macbook-charge-limit reset` (100% until you restart the service
  as above).
- Different limit: `mbp.chargeLimit.percent = 60;`. It only stops charging, it never discharges.

### 3. Wi-Fi: it works on the shipped `flake.lock`, think before updating

The Wi-Fi chip needs Broadcom's proprietary `wl` driver (the nixpkgs package `broadcom_sta`). It
is abandoned upstream; nixpkgs keeps it alive with patches. A newer kernel can stop it from
compiling, and then your system build fails or you end up without Wi-Fi.

- **Known good:** the `flake.lock` in this repository (nixpkgs and Home Manager from 15 October
  2026) with the default `linuxPackages_latest` kernel.
- **Do not `nix flake update` casually.** First run `nixos-rebuild build --flake .` (builds without
  activating anything). If it fails in `broadcom_sta`, do not switch.
- **If a newer kernel cannot compile the driver,** do yourself a favour and read the package on
  GitHub: `pkgs/os-specific/linux/broadcom-sta/default.nix` in nixpkgs. Its patch list and its
  `meta.broken` condition tell you the newest kernel it supports. Stay on that kernel:

  ```nix
  boot.kernelPackages = pkgs.linuxPackages_X_Y;   # the newest supported series, e.g. 6_12
  ```

  (The module's `linuxPackages_latest` is a `mkDefault`, so a plain assignment wins.)
- Keep old generations around (`configurationLimit = 3` in the example host) and an Ethernet
  adapter or phone tethering at hand: you need them for the install anyway.

## What the hardware profile does

| Area | What you get | File |
|---|---|---|
| Panel GPU | Intel HD 4000 drives the internal panel (an EFI variable tells the Apple firmware to switch the gmux at boot) | `hardware/igd-panel.nix` |
| NVIDIA GPU | Isolated from userspace and powered off once at boot (about 8-10 W saved); suspend stays clean | `hardware/igd-panel.nix` |
| Boot entries | normal, `desk` (NVIDIA on, for external monitors), `nvidia-panel` (nouveau drives the panel, fallback) | `hardware/routes.nix` |
| Wi-Fi | Broadcom needs the proprietary `wl` driver: blacklist of the free drivers, module, insecure-package permit | `hardware/hardware-fixes.nix` |
| Kernel / keys | `linuxPackages_latest`, `hid_apple.fnmode=1` (F1-F12 are media keys), `msr` for diagnostics, thermald | `hardware/hardware-fixes.nix` |
| Power | TLP + `tlp-pd` (keeps GNOME's Power Mode switch working), turbo off outside Performance | `hardware/power-tlp.nix` |
| Battery | 80% charge cap through the Apple SMC (`macbook-charge-limit`), because the kernel has no interface for Intel Macs yet | `hardware/power-tlp.nix`, `hardware/pkgs/` |
| No battery | Opt-in: removes the 1.2 GHz firmware throttle (see [below](#running-without-a-battery)) | `hardware/no-battery.nix` |
| nouveau reclock | Opt-in, experimental, hot: manual pstates + NVK Vulkan | `hardware/nouveau-reclock.nix` |
| Desktop glue | niri ignores the powered-off NVIDIA GPU; 200% HiDPI scale for GNOME and niri from one setting | `modules/`, `hosts/mbp/home.nix` |

## Which GPU setup? (why the default is the default)

The NVIDIA GPU on this machine is a trap in 2026:

1. The **proprietary driver** is the only one with hardware-accelerated video decoding on the
   NVIDIA GPU, but Kepler is stuck on the end-of-life `legacy_470` branch, which has **no usable
   Wayland support**. GNOME and niri are Wayland-first, so it is not an option. Do not use
   `hardware.nvidia` / PRIME from the NixOS wiki here.
2. The **nouveau** driver supports Wayland but has **no hardware-accelerated video playback**
   (the video engine firmware fails to load).
3. nouveau also has **unresolved bugs on Kepler**. The worst one: it kills GPU channels with page
   faults (`[PTE]` errors in the kernel log), which crashes GPU-accelerated apps (Firefox
   WebRender, Qt Quick) and once took down a whole GNOME session. Rendering on the CPU is the
   workaround, and it is slow.
4. By default the Apple firmware wires the panel to the NVIDIA GPU when Linux boots via EFI, so
   you are stuck with 2 and 3 all the time, hot and at 24-25 W.

So the profile makes **Intel drive the panel and powers the NVIDIA GPU off**. Everything else
costs stability. In short:

| Setup | Boot entry | Stability | Idle power (50% brightness) | Verdict |
|---|---|---|---|---|
| **Intel only** (NVIDIA off) | normal (first) | best | about 14-16 W | **Recommended, the default** |
| Intel panel, NVIDIA on for external monitors | `desk` | acceptable, not tested seriously | 24-25 W | OK when you need HDMI/DP |
| nouveau drives the panel | `nvidia-panel` | crashes, needs software rendering | 24-25 W | Fallback only (first boot, after macOS) |
| Proprietary NVIDIA driver | - | - | - | Not possible (no Wayland) |

If you pick anything other than the default, expect instability. That is the main finding of this
repository.

## Boot entries and the macOS round trip

systemd-boot shows three entries per generation:

| Entry | Panel on | NVIDIA GPU | Use it for |
|---|---|---|---|
| (normal) | Intel | powered off | everyday use |
| `desk` | Intel | on | external monitors (HDMI/DisplayPort belong to the NVIDIA GPU) |
| `nvidia-panel` | NVIDIA | on | the boot right after the install or after macOS |

**Why the fallback entry exists:** the firmware decides where the panel is *before* Linux starts,
from an EFI variable (`gpu-power-prefs`) that is consumed by every boot, ignored by macOS, and
armed by Linux at shutdown **only if the Intel GPU is driving the panel at that moment** (so a
broken boot can never re-arm itself). Consequences:

- **First boot after installing** and **first boot after macOS**: the panel is on the NVIDIA GPU.
  Pick `nvidia-panel` (it carries the nouveau workarounds), log in, run

  ```sh
  sudo dgpu-arm
  sudo reboot
  ```

  and boot the normal entry. From then on every Linux shutdown re-arms it.
- **Linux-only machine?** Set `mbp.igdPanel.armEveryBoot = true;` and skip the manual step after
  the first time (the first boot after macOS is still on NVIDIA).
- **Black screen after boot?** Hold the power button to power off, then power on holding
  `Cmd+Option+P+R` until the chime has played twice. That clears the variable; the next boot is the
  plain NVIDIA-panel setup and works.

`dgpu-status` (any entry) shows which GPU drives the panel, the power state of both GPUs and
whether the variable is armed.

## Installing

### A. Fresh install next to macOS

What you need: the Mac with macOS (OCLP or not, macOS is never touched), **at least 20 GiB of free
(unallocated) disk space**, a NixOS live USB, and **a USB Ethernet adapter or phone USB tethering**:
the live ISO has no driver for this Wi-Fi chip.

1. **Make room in macOS.** Check the identifiers with `diskutil list`, then shrink the APFS container
   (this leaves free space instead of a new volume; adjust the identifier and size):

   ```sh
   sudo diskutil apfs resizeContainer disk0s2 100g
   ```

2. **Boot the NixOS live USB:** hold `Option` at the chime, pick the USB's `EFI Boot`. Get online
   with Ethernet or tethering (`ip -br addr`).
3. **Get this repository** (clone it, or download and unpack the ZIP):

   ```sh
   git clone https://github.com/YOUR-USER/nixos-macbookpro10-1 && cd $(basename YOUR-USER/nixos-macbookpro10-1)
   ```

4. **Edit `hosts/mbp/settings.nix`:** user name, host name, time zone, locale.
5. **Run the installer as root** (use `bash`; flash drives are often mounted `noexec`):

   ```sh
   sudo bash scripts/install.sh
   ```

   It shows the plan, asks before it partitions or erases anything, then installs. See
   [The installer](#the-installer) for the steps and options.
6. **Reboot**, hold `Option`, pick the NixOS `EFI Boot` entry, then follow
   [Boot entries](#boot-entries-and-the-macos-round-trip): `nvidia-panel` first, `sudo dgpu-arm`,
   reboot into the normal entry.
7. Check it: `dgpu-status` should show the panel on `i915` and the NVIDIA GPU `Off`.

Later changes: `sudo nixos-rebuild switch --flake ~/nixos-macbookpro10-1` (the installer leaves a
copy of the repo in your home directory).

### B. Use it from your own flake

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-mbp.url = "github:YOUR-USER/nixos-macbookpro10-1";
    nixos-mbp.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nixos-mbp, ... }: {
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-mbp.nixosModules.default   # the whole hardware profile (./hardware)
        ./configuration.nix              # yours, with your hardware-configuration.nix
      ];
    };
  };
}
```

Without flakes: `imports = [ /path/to/this/repo/hardware/hardware-fixes.nix ];` works too.

Things the module does to your system, so nothing surprises you:

- sets `boot.kernelPackages = pkgs.linuxPackages_latest` (a `mkDefault`: override it with a plain
  assignment if you prefer an LTS kernel)
- builds the Broadcom `wl` Wi-Fi driver: enables `nixpkgs.config.allowUnfree` and permits the
  `broadcom_sta` package (nixpkgs marks it insecure; there is no free driver for this chip)
- enables TLP and forces `power-profiles-daemon` off (they cannot coexist), starts the charge-cap service
- adds the `desk` and `nvidia-panel` boot entries (specialisations) and two commands, `dgpu-arm` and `dgpu-status`
- sets a few session variables that only apply to the nouveau boots (see `hardware/routes.nix`)
- keeps nouveau loaded on purpose. **Do not blacklist it** and do not set `nouveau.modeset=0` or
  `acpi_backlight=native`: that breaks suspend, brightness or wake (details in the `hardware-fixes.nix` header)

Options (all under `mbp.`; set them from your own configuration with a normal assignment):

| Option | Default | Meaning |
|---|---|---|
| `panelGpu` | `"intel"` | `"nvidia"`: assume nouveau drives the panel (turns the workarounds on, the Intel machinery off) |
| `igdPanel.enable` | `true` | write the EFI variable so the Intel GPU drives the panel |
| `igdPanel.armEveryBoot` | `false` | also arm at every boot (Linux-only machines) |
| `igdPanel.isolateNvidia.enable` | `true` | isolate and power off the NVIDIA GPU at boot |
| `igdPanel.isolateNvidia.deskSpecialisation` | `true` | build the `desk` boot entry |
| `igdPanel.runtimePm.enable` | `false` | `nouveau.runpm=1`; measured: saves no power, cannot be combined with isolation |
| `nvidiaPanelSpecialisation` | `true` | build the `nvidia-panel` boot entry |
| `glRenderers.gsk.enable` / `.wgpu.enable` | route-dependent | `GSK_RENDERER=gl` / `WGPU_BACKEND=gl` (only needed when nouveau renders) |
| `softwareRendering.firefox.enable` / `.qt.enable` | route-dependent | CPU rendering to dodge nouveau crashes |
| `nouveauReclock.enable` | `false` | experimental manual reclocking (`acPstate`, `dcPstate`); needs `panelGpu = "nvidia"` |
| `noBattery.enable` | `false` | [no-battery mode](#running-without-a-battery) |
| `tlp.enable` | `true` | TLP + tlp-pd instead of power-profiles-daemon |
| `chargeLimit.enable` / `.percent` | `true` / `80` | SMC charge cap |

Using niri too? Import `nixos-mbp.nixosModules.niri` and the Home Manager modules
`nixos-mbp.homeManagerModules.{niri,mbp-niri-gpu,...}` as `hosts/mbp/home.nix` does. The GPU
glue matters: **niri opens every GPU it finds**, and touching the powered-off NVIDIA GPU kills it,
so `mbp-niri-gpu` tells niri to ignore it.

## Power and battery

Measured at 50% screen brightness, on battery:

| State | Draw |
|---|---|
| nouveau (or Intel + NVIDIA idle) | 24-25 W |
| `nouveau.runpm=1` (GPU suspended, `DynOff`) | still 24-25 W |
| **NVIDIA GPU powered off** (the default entry) | **about 14-16 W** |

Software side (`hardware/power-tlp.nix`): TLP with three profiles, selectable in GNOME's Power
Mode switch. Automatic: Balanced on AC, Power Saver on battery.

| | Performance | Balanced | Power Saver |
|---|---|---|---|
| Turbo Boost | allowed | off | off |
| Energy bias | balance_performance | balance_power | power |
| Intel GPU max | default | 800 MHz | - |

Turbo is off outside Performance because this 45 W quad-core runs much warmer in a thin chassis
with it on. Wi-Fi power saving is off (the `wl` driver is the fragile part). The CPU governor is
left alone.

**80% charge cap.** `macbook-charge-limit` writes the SMC keys BCLM/BFCL at boot and after resume
(upstream was tested on a MacBookAir6,2; it works on the MacBookPro10,1 too):

```sh
sudo macbook-charge-limit read     # expect BCLM=80 BFCL=80
sudo macbook-charge-limit reset    # full charge for travel, until:
sudo systemctl restart macbook-charge-limit
```

Change the number with `mbp.chargeLimit.percent`. It only stops charging; it never discharges.

### Running without a battery

A 2013 MacBook without its battery is throttled to **1.2 GHz** by the Mac firmware. As far as we
know the reason is a power shortage: without a battery the adapter alone must cover every load
peak, so the firmware asserts PROCHOT# on the CPU. `mbp.noBattery.enable = true;` clears that bit
(`BD_PROCHOT`) at boot and after every resume, **and locks turbo boost off**, so the CPU runs
at its base clock at most: **2.4 or 2.7 GHz depending on the model**. TLP, power-profiles-daemon
and the charge cap are switched off (GNOME then has no Power Mode toggle).

**Use it with the default Intel-only entry.** With the NVIDIA GPU powered off and turbo locked the
machine stays inside what the adapter can deliver, so you do not run into the power shortage that
is the root cause of Apple's throttle. The `desk` and `nvidia-panel` entries keep the NVIDIA GPU
powered, which brings that risk back.

Verify: `sudo rdmsr -a 0x1FC` must end in an even digit (also after a suspend/resume), and
`cat /sys/devices/system/cpu/intel_pstate/no_turbo` prints `1`.

## Handy commands

```sh
dgpu-status                                       # who drives the panel, GPU power, isolation
sudo dgpu-arm                                     # next boot: Intel drives the panel
systemctl status mbp-nvidia-isolate               # isolation + power-off at boot
sudo macbook-charge-limit read                    # battery cap
ls /sys/class/drm /sys/class/backlight            # want eDP-1 and gmux_backlight
readlink -f /run/booted-system                    # "-desk-" / "-nvidia-panel-" in the name = fallback entry
journalctl -k -b | grep -E "nouveau|stalled|PM:"  # after lid cycles: want only PM: suspend entry/exit
```

More checks are listed in the header of `hardware/hardware-fixes.nix`.

## Known issues and limits

- **No HDMI/DisplayPort in the normal entry.** Those ports belong to the NVIDIA GPU, which is off.
  Boot `desk`. (HDMI on the Intel panel is untested; `desk` with the GPU idle is not covered by a
  suspend test.)
- **The isolation applies at boot only.** `nixos-rebuild switch` on a running system does not
  power anything off; reboot. Turning the GPU off or on by hand on a running desktop
  (`vgaswitcheroo`) breaks suspend; do not.
- **Hardware video decoding:** none on the NVIDIA side (see above). The Intel GPU can decode H.264
  through VA-API with the i965 driver, but that is **not configured or tested here**.
- **`nvidia-panel` entry:** Firefox runs with software WebRender (heavy sites are slow), Qt Quick
  apps render on the CPU. That is the price of nouveau's page-fault crashes.
- **Ghost cursor** at login when the NVIDIA GPU drives the panel (after macOS): move the cursor
  off the screen, then log in.
- **Wi-Fi** uses an out-of-tree, insecure-flagged driver that a newer kernel can break: see
  [Wi-Fi: think before updating](#3-wi-fi-it-works-on-the-shipped-flakelock-think-before-updating).
- Only what is described here was verified. Camera, Thunderbolt, audio quality, etc. are whatever
  NixOS does on its own on this hardware.

## Troubleshooting

| Symptom | Try |
|---|---|
| Black screen after boot | Power off, `Cmd+Option+P+R` at power-on (see above), boot `nvidia-panel` |
| Brightness keys do nothing | `cat /proc/cmdline`: there must be no `acpi_backlight=`; `ls /sys/class/backlight` must show `gmux_backlight` |
| Panel is on NVIDIA again | You booted macOS, or the last shutdown was not on Intel: `sudo dgpu-arm`, reboot |
| Battery charges past 80% | A PRAM/NVRAM and/or SMC reset lifted the cap: `sudo systemctl restart macbook-charge-limit`, check with `sudo macbook-charge-limit read` |
| `error: path '.../hardware-configuration.nix' does not exist` | Flakes only see files known to git: `git add hosts/mbp/hardware-configuration.nix` |
| `nixos-rebuild` or `nixos-install` cannot build `broadcom_sta` | Pin an older kernel, see [Wi-Fi](#3-wi-fi-it-works-on-the-shipped-flakelock-think-before-updating) |
| `mbp-nvidia-isolate` is `failed` | The unit backed out on purpose and left the GPU on; read `journalctl -b -u mbp-nvidia-isolate` |
| GTK4 apps draw garbled text after resume (nouveau boots) | `GSK_RENDERER=gl`, already set by the `nvidia-panel` entry |

## The installer

`scripts/install.sh` runs from the NixOS live USB and is split into steps that can be skipped,
repeated or started from. Finished steps are detected and skipped on a rerun.

```sh
sudo bash scripts/install.sh --help
sudo bash scripts/install.sh status             # which steps look done
sudo bash scripts/install.sh --from hwconfig    # resume at a step
sudo bash scripts/install.sh install            # rerun one step
sudo bash scripts/install.sh --dry-run          # show the plan only
```

| Step | What it does |
|---|---|
| `preflight` | checks root, EFI boot and the machine, finds the repo and the target disk |
| `net` | checks internet access (cache.nixos.org) |
| `wgcf-up` | optional (`--wgcf`): WARP WireGuard tunnel from a `wgcf-profile.conf`, for regions with slow downloads from the cache CDN |
| `partition` | creates partition 3 (1 GiB EFI, label `NIXBOOT`) and 4 (btrfs, the rest) in the free space; **macOS partitions are not touched** |
| `format` | formats them, btrfs subvolumes `@`, `@home`, `@nix` |
| `mount` | mounts everything under `/mnt` (`noatime,compress=zstd:1`) |
| `stage` / `hwconfig` / `syncback` | copies the repo to RAM, generates `hardware-configuration.nix` for your disk, copies it back |
| `check` | evaluates the flake before the long download |
| `install` | `nixos-install --flake` (long; a rerun resumes) |
| `password` | sets the login password of your user |
| `copy-repo` | leaves a copy of the repo in your home directory |
| `finish` | unmounts and prints the next steps |

Assumptions: a GPT disk where macOS uses partitions 1 (EFI) and 2 (APFS) and the new ones become 3
and 4, and the internal disk is found by its APFS partition (`--disk /dev/sdX` overrides). It asks
you to type `yes` before partitioning or formatting. Extra steps, only when named: `wgcf-down`,
`unmount`, `wipe-linux` (deletes partitions 3 and 4 again).

`wgcf-profile.conf` holds a private key; `.gitignore` keeps it out of git.

## Repository layout

```
.
├── flake.nix                 outputs: nixosModules, homeManagerModules, the example host
├── hardware/                 THE POINT OF THIS REPO; import hardware-fixes.nix
│   ├── hardware-fixes.nix    entry point: kernel, Wi-Fi, thermald; imports the rest
│   ├── igd-panel.nix         Intel drives the panel, NVIDIA isolation, dgpu-arm / dgpu-status
│   ├── routes.nix            boot entries (desk / nvidia-panel) and route-dependent settings
│   ├── power-tlp.nix         TLP profiles and the 80% charge cap
│   ├── no-battery.nix        opt-in: no-battery workarounds
│   ├── nouveau-reclock.nix   opt-in, experimental: reclock the NVIDIA GPU
│   └── pkgs/macbook-charge-limit.nix
├── modules/                  optional desktop pieces that know about the GPU routing
│   ├── nixos/niri.nix        niri session, system side
│   └── home/                 niri config, GPU rules, Alacritty, fonts, HiDPI knobs
├── hosts/mbp/                the example host
│   ├── settings.nix          user / host / time zone: edit this
│   ├── configuration.nix     boot, zram, btrfs options, GNOME + GDM, one user
│   └── home.nix              Home Manager: 200% scale, GNOME settings, niri
└── scripts/install.sh        the installer
```

`hosts/mbp/hardware-configuration.nix` is generated by the installer for your disk and is not in
this repository.

## Credits and license

[MIT](LICENSE). `hardware/pkgs/macbook-charge-limit.nix` packages
[jtbrough/macbook-charge-limit](https://github.com/jtbrough/macbook-charge-limit) (MIT). Useful
background: the Arch Wiki page "MacBookPro10,x", the kernel's `apple-gmux` documentation, and
mutter's `doc/multi-gpu.md`.
