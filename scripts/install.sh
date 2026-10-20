#!/usr/bin/env bash
# =============================================================================
# install.sh -- install this repo's NixOS configuration next to macOS (OCLP) on a
# 2013 MacBook Pro, from the NixOS live USB. Every phase is a separate step that
# can be skipped, rerun, or started from.
#
#   sudo bash scripts/install.sh --help
#   sudo bash scripts/install.sh status
#
# It finds the repo root by walking up to flake.nix. Run with `bash` (flash drives
# are often noexec). Edit hosts/mbp/settings.nix first: user name, host name, time
# zone. The disk layout it creates is described in the README ("The installer").
# =============================================================================
set -Eeuo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
PROG=$(basename "$SELF")
ORIG_ARGS=("$@")

# ---- constants (override with env vars if you really want) ------------------
STATE_FILE=/tmp/mbp-install.env
MNT=/mnt
ESP_SIZE=1G
LABEL_BOOT=NIXBOOT
LABEL_ROOT=nixos
BTRFS_OPTS="noatime,compress=zstd:1"
APFS_GUID=7c3457ef-0000-11aa-aa11-00306543ecac   # partition type of macOS APFS
WG_IFACE=wgcf
WG_CONF=/tmp/$WG_IFACE.conf
DEST_NAME=nixos-macbookpro10-1                    # the repo copy goes to ~/nixos-macbookpro10-1
HOST_DIR=hosts/mbp                                # the example host inside the repo

# ---- settings that persist between runs (kept in $STATE_FILE) ---------------
# HOST and TARGET_USER default to hostName / userName from hosts/mbp/settings.nix
# (read in main); --host / --user or the environment override them.
HOST=${HOST:-mbp}
TARGET_USER=${TARGET_USER:-user}
DISK=${DISK:-}
SRC=${SRC:-}
STAGE=${STAGE:-/tmp/nixos-mbp}
WGCF_PROFILE=${WGCF_PROFILE:-}

# ---- per-run flags -----------------------------------------------------------
YES=0 REDO=0 WGCF=0 DRY=0 FROM="" SKIP="" HOST_FORCED=0 USER_FORCED=0
REQUESTED=()

ALL_STEPS=(preflight net wgcf-up partition format mount stage hwconfig
           syncback check install password copy-repo finish)
EXTRA_STEPS=(wgcf-down status unmount wipe-linux)

# ---- output helpers ----------------------------------------------------------
if [[ -t 2 ]]; then
  C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_B=$'\e[1m' C_0=$'\e[0m'
else
  C_G="" C_Y="" C_R="" C_B="" C_0=""
fi
say()  { printf '%s==>%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s!!%s  %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sxx%s  %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

desc() {
  case $1 in
    preflight)  echo "check root/EFI/machine, locate the repo, find the target disk" ;;
    net)        echo "verify internet access (cache.nixos.org) and show WARP state" ;;
    wgcf-up)    echo "(optional) bring up the WARP WireGuard tunnel from a wgcf profile" ;;
    wgcf-down)  echo "(optional) take the tunnel down again" ;;
    partition)  echo "create ${ESP_SIZE} ${LABEL_BOOT} ESP + btrfs partition in the free space" ;;
    format)     echo "mkfs vfat + btrfs, create subvolumes @ @home @nix" ;;
    mount)      echo "mount everything under $MNT" ;;
    stage)      echo "copy the repo to a RAM working copy ($STAGE)" ;;
    hwconfig)   echo "generate hardware-configuration.nix into the working copy" ;;
    syncback)   echo "copy the new hardware-configuration.nix back to the repo on the USB" ;;
    check)      echo "evaluate the flake (catches config errors before the long download)" ;;
    install)    echo "nixos-install --flake (long; safe to rerun, it resumes)" ;;
    password)   echo "set the login password for $TARGET_USER" ;;
    copy-repo)  echo "put a copy of the repo in /home/$TARGET_USER/$DEST_NAME" ;;
    finish)     echo "sync, unmount, print the next steps" ;;
    status)     echo "show which steps already look done" ;;
    unmount)    echo "umount -R $MNT" ;;
    wipe-linux) echo "DANGEROUS: delete the two NixOS partitions again" ;;
  esac
}

usage() {
  cat <<EOF
Usage: bash $PROG [options] [step ...]

  (no step)      run every step in order; steps that already look done are
                 skipped automatically (see 'status')
  step ...       run exactly these steps, in the order given

Options:
  --from STEP        start at STEP (it always runs), then continue in order
  --skip A,B         leave these steps out
  --only / (steps)   same as listing steps positionally
  --redo             do not auto-skip finished steps; allow reformat/re-stage
  --wgcf             include the optional wgcf-up step in a full run
  --wgcf-profile F   path to wgcf-profile.conf (implies --wgcf)
  --disk DEV         target disk, e.g. /dev/sda (auto-detected otherwise)
  --host NAME        flake host (default: hostName in hosts/mbp/settings.nix)
  --user NAME        login user (default: userName in hosts/mbp/settings.nix)
  --repo DIR         repo root (default: found from the script location)
  -n, --dry-run      show what would run, do nothing
  -y, --yes          skip confirmation prompts (dangerous)
  --list             list steps       -h, --help   this text

Examples:
  bash $PROG status
  bash $PROG                          # everything
  bash $PROG --wgcf                   # everything, with the WARP tunnel
  bash $PROG --from hwconfig          # resume from hwconfig
  bash $PROG hwconfig syncback check  # just those three
  bash $PROG install                  # rerun only the install
EOF
}

list_steps() {
  local s
  echo "Steps in a full run:"
  for s in "${ALL_STEPS[@]}"; do printf '  %-11s %s\n' "$s" "$(desc "$s")"; done
  echo "Extra steps (only when named):"
  for s in "${EXTRA_STEPS[@]}"; do printf '  %-11s %s\n' "$s" "$(desc "$s")"; done
}

# ---- state ---------------------------------------------------------------------
save_state() {
  local v
  { for v in HOST TARGET_USER DISK SRC STAGE WGCF_PROFILE; do
      printf '%s=%q\n' "$v" "${!v-}"
    done; } >"$STATE_FILE"
}
load_state() { if [[ -f $STATE_FILE ]]; then . "$STATE_FILE"; fi; }

# ---- small helpers -------------------------------------------------------------
partdev() {
  case $DISK in
    *[0-9]) printf '%sp%s' "$DISK" "$1" ;;
    *)      printf '%s%s' "$DISK" "$1" ;;
  esac
}

confirm_typed() {  # confirm_typed "what will happen" [word]
  local prompt=$1 word=${2:-yes} ans=""
  if ((YES)); then warn "--yes given, not asking: $prompt"; return 0; fi
  read -r -p "$prompt Type '$word' to continue: " ans </dev/tty || true
  [[ $ans == "$word" ]] || die "aborted"
}

settings_get() {  # settings_get KEY -> value of  KEY = "value";  in hosts/mbp/settings.nix
  local f=$SRC/$HOST_DIR/settings.nix
  [[ -f $f ]] || return 1
  sed -n 's/^[[:space:]]*'"$1"'[[:space:]]*=[[:space:]]*"\([^"]*\)";.*/\1/p' "$f" | head -n 1
}

find_repo() {
  local d
  d=$(dirname "$SELF")
  while [[ $d != / ]]; do
    [[ -f $d/flake.nix ]] && { printf '%s' "$d"; return 0; }
    d=$(dirname "$d")
  done
  return 1
}

detect_disk() {
  local d found=()
  while read -r d; do
    if lsblk -rno PARTTYPE "/dev/$d" 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$APFS_GUID"; then
      found+=("/dev/$d")
    fi
  done < <(lsblk -dnro NAME,TYPE | awk '$2=="disk"{print $1}')
  case ${#found[@]} in
    1) printf '%s' "${found[0]}" ;;
    0) return 1 ;;
    *) warn "several disks with an APFS partition: ${found[*]}"; return 1 ;;
  esac
}

resolve_disk() {
  if [[ -z $DISK ]]; then
    DISK=$(detect_disk) || die "could not auto-detect the internal disk; pass --disk /dev/sdX (see lsblk)"
  fi
  [[ -b $DISK ]] || die "$DISK is not a block device"
  save_state
}

trace_has_warp() { grep -Eq '^warp=(on|plus)$' <<<"$1"; }

# ---- "is this step done?" checks (used by status and auto-skip) -------------------
done_wgcf_up()   { ip link show "$WG_IFACE" >/dev/null 2>&1; }
done_partition() {
  [[ -n $DISK && -b $(partdev 3) && -b $(partdev 4) ]] &&
    [[ $(lsblk -rno PARTLABEL "$(partdev 4)" 2>/dev/null) == "$LABEL_ROOT" ]]
}
done_format() {
  [[ -n $DISK ]] &&
    [[ $(blkid -s TYPE -o value "$(partdev 4)" 2>/dev/null) == btrfs ]] &&
    [[ $(blkid -s TYPE -o value "$(partdev 3)" 2>/dev/null) == vfat ]]
}
done_mount() {
  mountpoint -q "$MNT/boot" && mountpoint -q "$MNT/nix" && mountpoint -q "$MNT/home"
}
done_stage()     { [[ -f $STAGE/flake.nix ]]; }
done_hwconfig() {
  local f=$STAGE/$HOST_DIR/hardware-configuration.nix uuid
  [[ -n $DISK && -f $f ]] || return 1
  uuid=$(blkid -s UUID -o value "$(partdev 4)" 2>/dev/null) || return 1
  [[ -n $uuid ]] && grep -q "$uuid" "$f"
}
done_syncback() {
  [[ -n $SRC ]] || return 1
  [[ $SRC != "$STAGE" ]] || return 0
  cmp -s "$STAGE/$HOST_DIR/hardware-configuration.nix" "$SRC/$HOST_DIR/hardware-configuration.nix"
}
done_install()   { [[ -e $MNT/nix/var/nix/profiles/system ]]; }
done_password() {
  local h
  h=$(awk -F: -v u="$TARGET_USER" '$1==u{print $2}' "$MNT/etc/shadow" 2>/dev/null) || return 1
  [[ -n $h && $h != '!'* && $h != '*'* ]]
}
done_copy_repo() { [[ -d $MNT/home/$TARGET_USER/$DEST_NAME/.git || -f $MNT/home/$TARGET_USER/$DEST_NAME/flake.nix ]]; }

is_done() {  # step name -> exit 0 if it already looks done
  local fn="done_${1//-/_}"
  declare -F "$fn" >/dev/null || return 1
  "$fn"
}

# =============================================================================
# STEPS (each runs in its own subshell with `set -e`)
# =============================================================================

step_preflight() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo -i first)"
  [[ -d /sys/firmware/efi ]] || die "not booted via EFI -- hold Option at the chime and pick the USB 'EFI Boot' entry"
  local product
  product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  say "machine: ${product:-unknown}"
  [[ $product == MacBookPro* ]] || warn "this does not look like a MacBook Pro -- are you on the right machine?"

  [[ -n $SRC ]] || SRC=$(find_repo) || die "cannot find the repo (no flake.nix above $SELF); pass --repo DIR"
  [[ -f $SRC/flake.nix ]] || die "$SRC/flake.nix missing"
  [[ -f $SRC/$HOST_DIR/configuration.nix ]] || die "$SRC/$HOST_DIR/configuration.nix missing (is --repo the repo root?)"
  [[ -n $HOST && -n $TARGET_USER ]] || die "no host/user name: fix $HOST_DIR/settings.nix or pass --host / --user"
  say "repo: $SRC   host: $HOST   user: $TARGET_USER"

  resolve_disk
  say "target disk: $DISK"
  lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTLABEL,MOUNTPOINTS "$DISK"
}

step_net() {
  if ! curl -fsS -m 10 -o /dev/null https://cache.nixos.org/nix-cache-info; then
    warn "cannot reach cache.nixos.org."
    warn "Wi-Fi will NOT work in the live ISO (this Mac needs the proprietary wl driver)."
    warn "Use a USB Ethernet adapter or USB tethering from a phone, then check: ip -br addr"
    die "no internet"
  fi
  say "cache.nixos.org reachable"
  curl -fsS -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
    grep -E '^(ip|loc|warp)=' >&2 || warn "could not read the Cloudflare trace"
}

find_wgcf_profile() {
  local d f
  for d in "$SRC" "$(dirname "$SRC")" /run/media/* /media/* /mnt/usb*; do
    for f in "$d/wgcf-profile.conf" "$d/wgcf/wgcf-profile.conf"; do
      [[ -f $f ]] && { printf '%s' "$f"; return 0; }
    done
  done
  return 1
}

step_wgcf_up() {
  local trace profile
  trace=$(curl -fsS -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  if trace_has_warp "$trace"; then
    say "this connection already goes through WARP (router policy?) -- not stacking a second tunnel"
    return 0
  fi
  profile=${WGCF_PROFILE:-}
  [[ -n $profile ]] || profile=$(find_wgcf_profile) ||
    die "no wgcf-profile.conf found; pass --wgcf-profile FILE (generate it elsewhere with: wgcf register && wgcf generate)"
  [[ -f $profile ]] || die "$profile not found"
  say "using $profile"
  warn "keep that file OUT of git: it contains your WARP private key"

  install -m 600 "$profile" "$WG_CONF"
  sed -i -e '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF"   # live ISO has no resolvconf
  grep -q '^[[:space:]]*MTU' "$WG_CONF" || sed -i '/^\[Interface\]/a MTU = 1280' "$WG_CONF"

  if ip link show "$WG_IFACE" >/dev/null 2>&1; then wg-quick down "$WG_CONF" || true; fi
  if ! wg-quick up "$WG_CONF"; then
    warn "retrying without the IPv6 default route"
    wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    sed -i -E 's#,[[:space:]]*::/0##' "$WG_CONF"
    wg-quick up "$WG_CONF" || die "tunnel failed. Try another endpoint port (500, 1701, 4500) in $WG_CONF"
  fi
  sleep 2
  trace=$(curl -fsS -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  if trace_has_warp "$trace"; then
    say "WARP is on. Compare download speed; 'bash $PROG wgcf-down' turns it off."
  else
    warn "tunnel is up but the trace does not say warp=on; check 'wg show'"
  fi
}

step_wgcf_down() {
  if ip link show "$WG_IFACE" >/dev/null 2>&1; then
    wg-quick down "$WG_CONF"
  else
    say "tunnel is not up"
  fi
}

step_partition() {
  resolve_disk
  local p3 p4 free ss s3 s4
  p3=$(partdev 3); p4=$(partdev 4)

  if [[ -b $p3 || -b $p4 ]]; then
    if [[ $(lsblk -rno PARTLABEL "$p3" 2>/dev/null) == "$LABEL_BOOT" &&
          $(lsblk -rno PARTLABEL "$p4" 2>/dev/null) == "$LABEL_ROOT" ]]; then
      say "partitions $p3 ($LABEL_BOOT) and $p4 ($LABEL_ROOT) already exist -- nothing to do"
      return 0
    fi
    die "$p3 / $p4 already exist but are not ours. Inspect with: sgdisk -p $DISK"
  fi

  sgdisk -p "$DISK"
  free=$(sgdisk -p "$DISK" | sed -n 's/^Total free space is \([0-9]*\) sectors.*/\1/p')
  ss=$(blockdev --getss "$DISK")
  (( ${free:-0} * ss >= 20 * 1024 * 1024 * 1024 )) ||
    die "less than 20 GiB of free space on $DISK -- refusing"

  say "will create in the free space of $DISK:"
  say "  3: ${ESP_SIZE} EFI System  '$LABEL_BOOT'    4: rest, Linux  '$LABEL_ROOT'"
  say "partitions 1 and 2 (macOS EFI + APFS) are not touched"
  confirm_typed "Partition $DISK?" yes

  s3=$(sgdisk -F "$DISK")
  sgdisk -n "3:$s3:+$ESP_SIZE" -t 3:ef00 -c "3:$LABEL_BOOT" "$DISK"
  s4=$(sgdisk -F "$DISK")
  sgdisk -n "4:$s4:0" -t 4:8300 -c "4:$LABEL_ROOT" "$DISK"
  partprobe "$DISK" || true
  udevadm settle
  sgdisk -p "$DISK"
}

step_format() {
  resolve_disk
  local p3 p4
  p3=$(partdev 3); p4=$(partdev 4)
  [[ -b $p3 && -b $p4 ]] || die "run the 'partition' step first"
  [[ $(lsblk -rno PARTLABEL "$p3") == "$LABEL_BOOT" && $(lsblk -rno PARTLABEL "$p4") == "$LABEL_ROOT" ]] ||
    die "$p3/$p4 are not the NixOS partitions -- refusing to format"

  if done_format && ((REDO == 0)); then
    say "already formatted (btrfs + vfat). Use --redo to wipe and reformat."
    return 0
  fi
  confirm_typed "ERASE $p3 and $p4 and create fresh filesystems?" yes

  if mountpoint -q "$MNT"; then umount -R "$MNT"; fi
  wipefs -a "$p3" "$p4"
  mkfs.vfat -F32 -n "$LABEL_BOOT" "$p3"
  mkfs.btrfs -f -L "$LABEL_ROOT" "$p4"

  mount "$p4" "$MNT"
  btrfs subvolume create "$MNT/@"
  btrfs subvolume create "$MNT/@home"
  btrfs subvolume create "$MNT/@nix"
  umount "$MNT"
  say "formatted; subvolumes @ @home @nix created"
}

step_mount() {
  resolve_disk
  local p3 p4
  p3=$(partdev 3); p4=$(partdev 4)
  [[ $(blkid -s TYPE -o value "$p4" 2>/dev/null) == btrfs ]] || die "run the 'format' step first"

  mountpoint -q "$MNT" || mount -o "$BTRFS_OPTS,subvol=@" "$p4" "$MNT"
  mkdir -p "$MNT"/{boot,home,nix}
  mountpoint -q "$MNT/home" || mount -o "$BTRFS_OPTS,subvol=@home" "$p4" "$MNT/home"
  mountpoint -q "$MNT/nix"  || mount -o "$BTRFS_OPTS,subvol=@nix"  "$p4" "$MNT/nix"
  mountpoint -q "$MNT/boot" || mount -o fmask=0077,dmask=0077 "$p3" "$MNT/boot"
  findmnt -R "$MNT"
}

step_stage() {
  [[ -n $SRC ]] || die "run 'preflight' first (it locates the repo)"
  if [[ $SRC == "$STAGE" ]]; then say "repo is already the working copy"; return 0; fi
  if [[ -f $STAGE/flake.nix ]] && ((REDO == 0)); then
    say "$STAGE already exists. Use --redo to re-copy (this discards its hardware-configuration; rerun 'hwconfig' after)."
    return 0
  fi
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -a "$SRC/." "$STAGE/"
  # the USB stick's files have other owners/modes; stop git from complaining as root
  command -v git >/dev/null && git config --global --add safe.directory '*'
  say "copied $SRC -> $STAGE"
}

step_hwconfig() {
  resolve_disk
  done_mount || die "run the 'mount' step first"
  [[ -d $STAGE/$HOST_DIR ]] || die "run the 'stage' step first"
  local out=$STAGE/$HOST_DIR/hardware-configuration.nix tmp
  tmp=$(mktemp)
  nixos-generate-config --root "$MNT" --show-hardware-config >"$tmp"

  grep -q 'subvol=@home' "$tmp" || die "generated config has no @home mount -- are the subvolumes mounted?"
  grep -q 'subvol=@nix'  "$tmp" || die "generated config has no @nix mount"
  grep -q 'fileSystems."/boot"' "$tmp" || die "generated config has no /boot"
  grep -Eq 'swapDevices *= *\[ *\]' "$tmp" || warn "swapDevices is not empty -- this configuration expects zram only"

  [[ -f $out ]] && cp -a "$out" "/tmp/hardware-configuration.nix.before"
  mv "$tmp" "$out"
  if git -C "$STAGE" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$STAGE" add "$HOST_DIR/hardware-configuration.nix" || warn "git add failed"
  else
    warn "$STAGE is not a git repo; fine for 'path:' flakes, but then use path: refs yourself"
  fi
  say "wrote $out"
  grep -A4 'fileSystems' "$out" | grep -E 'fileSystems|device|subvol' >&2 || true
}

step_syncback() {
  [[ -n $SRC && $SRC != "$STAGE" ]] || { say "nothing to sync (repo is the working copy)"; return 0; }
  local f=$HOST_DIR/hardware-configuration.nix
  [[ -f $STAGE/$f ]] || die "no generated $f -- run 'hwconfig' first"
  if cp "$STAGE/$f" "$SRC/$f"; then
    say "copied to $SRC/$f  (commit it later: git add $f && git commit)"
  else
    warn "could not write to $SRC (read-only stick?). Copy $STAGE/$f by hand."
  fi
}

step_check() {
  [[ -f $STAGE/$HOST_DIR/hardware-configuration.nix ]] || die "run 'hwconfig' first"
  say "evaluating nixosConfigurations.$HOST (downloads flake inputs, no builds)"
  if ! nix eval --raw "$STAGE#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath"; then
    warn "evaluation failed. Fix the repo (edit $SRC), then: bash $PROG stage --redo hwconfig check"
    return 1
  fi
  echo
  say "evaluation OK"
}

step_install() {
  done_mount || die "run the 'mount' step first"
  [[ -f $STAGE/flake.nix ]] || die "run the 'stage' step first"
  say "installing $HOST from $STAGE -- this is the long download/build; rerunning later resumes"
  nixos-install --root "$MNT" --flake "$STAGE#$HOST" --no-root-passwd --no-channel-copy
}

step_password() {
  [[ -e $MNT/etc/shadow ]] || die "no $MNT/etc/shadow -- did 'install' finish?"
  grep -q "^$TARGET_USER:" "$MNT/etc/shadow" || die "user $TARGET_USER does not exist in the installed system"
  if done_password && ((REDO == 0)); then
    say "$TARGET_USER already has a password. Use --redo to change it."
    return 0
  fi
  nixos-enter --root "$MNT" -c "passwd $TARGET_USER"
}

step_copy_repo() {
  [[ -f $STAGE/flake.nix ]] || die "no working copy at $STAGE"
  local home=$MNT/home/$TARGET_USER dest uid gid
  dest=$home/$DEST_NAME
  IFS=: read -r _ _ uid gid _ < <(grep "^$TARGET_USER:" "$MNT/etc/passwd") ||
    die "user $TARGET_USER not in $MNT/etc/passwd"
  if [[ ! -d $home ]]; then mkdir -p "$home"; chown "$uid:$gid" "$home"; chmod 700 "$home"; fi
  if [[ -e $dest ]] && ((REDO == 0)); then
    say "$dest already exists. Use --redo to replace it."
    return 0
  fi
  rm -rf "$dest"
  cp -a "$STAGE" "$dest"
  chown -R "$uid:$gid" "$dest"
  say "repo copied to /home/$TARGET_USER/$DEST_NAME"
}

step_finish() {
  sync
  if ip link show "$WG_IFACE" >/dev/null 2>&1; then wg-quick down "$WG_CONF" || true; fi
  if mountpoint -q "$MNT"; then umount -R "$MNT"; fi
  cat >&2 <<EOF

${C_B}Done. Next:${C_0}
  1. reboot, unplug the USB, hold Option at the chime and pick the NixOS "EFI Boot"
     entry (if you land in OpenCore/macOS instead, reboot and pick the other one)
  2. in the systemd-boot menu pick the "nvidia-panel" entry for this FIRST boot. Nothing has
     told the firmware yet to put the panel on the Intel GPU, so nouveau drives the screen
     and that entry carries the workarounds for it
  3. log in as $TARGET_USER; the repo is in ~/$DEST_NAME
       cd ~/$DEST_NAME && git status      # hardware-configuration.nix is new: commit it
       sudo dgpu-arm                      # next boot: the Intel GPU drives the panel
       sudo reboot                        # then boot the first (normal) entry
  4. health check (details in the README):
       dgpu-status                                # panel on i915, NVIDIA GPU Off
       systemctl status mbp-nvidia-isolate tlp tlp-pd macbook-charge-limit
       sudo macbook-charge-limit read             # BCLM=80 BFCL=80
       ls /sys/class/drm /sys/class/backlight     # want eDP-1 and gmux_backlight
       ip -br link                                # Wi-Fi interface (wl driver)
  5. later changes:  sudo nixos-rebuild switch --flake ~/$DEST_NAME
EOF
}

step_status() {
  local s mark
  printf '%-11s %s\n' step state >&2
  for s in "${ALL_STEPS[@]}"; do
    if is_done "$s"; then mark="${C_G}done${C_0}"; else mark="--"; fi
    printf '%-11s %s\n' "$s" "$mark" >&2
  done
  [[ -n $DISK ]] && say "disk: $DISK   repo: ${SRC:-?}   working copy: $STAGE   host: $HOST   user: $TARGET_USER"
  warn "'done' is a quick heuristic; preflight/net/check/finish are cheap and always rerun."
}

step_unmount() {
  if mountpoint -q "$MNT"; then umount -R "$MNT"; say "unmounted $MNT"; else say "$MNT is not mounted"; fi
}

step_wipe_linux() {
  resolve_disk
  local p3 p4
  p3=$(partdev 3); p4=$(partdev 4)
  [[ $(lsblk -rno PARTLABEL "$p3" 2>/dev/null) == "$LABEL_BOOT" &&
     $(lsblk -rno PARTLABEL "$p4" 2>/dev/null) == "$LABEL_ROOT" ]] ||
    die "partitions 3/4 on $DISK are not the NixOS ones -- refusing"
  confirm_typed "DELETE partitions $p3 and $p4 (and everything on them)?" delete
  if mountpoint -q "$MNT"; then umount -R "$MNT"; fi
  sgdisk -d 4 -d 3 "$DISK"
  partprobe "$DISK" || true
  say "deleted; macOS partitions untouched"
}

# =============================================================================
# driver
# =============================================================================

valid_step() {
  local s
  for s in "${ALL_STEPS[@]}" "${EXTRA_STEPS[@]}"; do [[ $s == "$1" ]] && return 0; done
  return 1
}

in_skip_list() { [[ ,$SKIP, == *,"$1",* ]]; }

tools_for() {  # step -> "cmd:nixpkgs-attr" pairs
  case $1 in
    net)        echo "curl:curl" ;;
    wgcf-up)    echo "wg-quick:wireguard-tools curl:curl ip:iproute2" ;;
    wgcf-down)  echo "wg-quick:wireguard-tools" ;;
    partition|wipe-linux) echo "sgdisk:gptfdisk partprobe:parted lsblk:util-linux" ;;
    format)     echo "mkfs.vfat:dosfstools mkfs.btrfs:btrfs-progs wipefs:util-linux" ;;
    mount)      echo "btrfs:btrfs-progs" ;;
    hwconfig|stage) echo "git:git" ;;
  esac
}

ensure_tools() {  # run once, in the main shell, so a re-exec restarts cleanly
  local s pair missing=() pkgs=()
  for s in "$@"; do
    for pair in $(tools_for "$s"); do
      command -v "${pair%%:*}" >/dev/null 2>&1 || {
        missing+=("${pair%%:*}"); pkgs+=("nixpkgs#${pair##*:}")
      }
    done
  done
  ((${#missing[@]})) || return 0
  [[ -z ${MBP_REEXEC:-} ]] || die "still missing after 'nix shell': ${missing[*]}"
  warn "missing tools: ${missing[*]} -- re-running inside 'nix shell' (needs internet)"
  MBP_REEXEC=1 exec nix shell "${pkgs[@]}" -c "$SELF" "${ORIG_ARGS[@]}"
}

run_step() {
  local s=$1 rc
  set +e
  ( set -Eeuo pipefail; "step_${s//-/_}" )
  rc=$?
  set -e
  load_state
  if ((rc != 0)); then
    echo >&2
    warn "step '$s' failed (exit $rc). Fix the cause, then either:"
    warn "  rerun just this step:      bash $PROG $s"
    warn "  or continue from it:       bash $PROG --from $s"
    exit "$rc"
  fi
}

main() {
  export NIX_CONFIG="experimental-features = nix-command flakes"
  load_state

  while (($#)); do
    case $1 in
      -h|--help|help) usage; exit 0 ;;
      --list|list)    list_steps; exit 0 ;;
      --disk)         DISK=${2:?--disk needs a value}; shift ;;
      --host)         HOST=${2:?}; HOST_FORCED=1; shift ;;
      --user)         TARGET_USER=${2:?}; USER_FORCED=1; shift ;;
      --repo)         SRC=$(readlink -f "${2:?}"); shift ;;
      --wgcf)         WGCF=1 ;;
      --wgcf-profile) WGCF_PROFILE=$(readlink -f "${2:?}"); WGCF=1; shift ;;
      --from)         FROM=${2:?}; shift ;;
      --skip)         SKIP=${2:?}; shift ;;
      --only)         shift; REQUESTED+=("${1:?--only needs a step}") ;;
      --redo)         REDO=1 ;;
      -y|--yes)       YES=1 ;;
      -n|--dry-run)   DRY=1 ;;
      -*)             die "unknown option: $1 (try --help)" ;;
      *)              REQUESTED+=("$1") ;;
    esac
    shift
  done

  [[ -n $SRC ]] || SRC=$(find_repo || true)   # needed for the done-checks below

  # hostName / userName come from settings.nix unless given on the command line.
  if [[ -n $SRC ]]; then
    local v
    if ((HOST_FORCED == 0)); then v=$(settings_get hostName || true); [[ -z $v ]] || HOST=$v; fi
    if ((USER_FORCED == 0)); then v=$(settings_get userName || true); [[ -z $v ]] || TARGET_USER=$v; fi
  fi

  local s
  for s in "${REQUESTED[@]}" ${FROM:+"$FROM"}; do
    valid_step "$s" || die "unknown step '$s' (try --list)"
  done
  if [[ -n $SKIP ]]; then
    for s in ${SKIP//,/ }; do valid_step "$s" || die "unknown step '$s' in --skip"; done
  fi

  # ---- build the plan ----
  local plan=() auto_skipped=() started=1
  if ((${#REQUESTED[@]})); then
    plan=("${REQUESTED[@]}")
  else
    [[ -z $FROM ]] || started=0
    for s in "${ALL_STEPS[@]}"; do
      [[ $s != "$FROM" ]] || started=1
      ((started)) || continue
      in_skip_list "$s" && continue
      [[ $s != wgcf-up ]] || ((WGCF)) || continue
      if ((REDO == 0)) && [[ $s != "$FROM" ]] && is_done "$s"; then
        auto_skipped+=("$s"); continue
      fi
      plan+=("$s")
    done
  fi

  if ((${#auto_skipped[@]})); then say "already done, skipping: ${auto_skipped[*]}  (--redo to force)"; fi
  say "plan: ${plan[*]:-(nothing)}"
  if ((DRY)); then exit 0; fi
  ((${#plan[@]})) || exit 0

  local needs_root=0
  for s in "${plan[@]}"; do [[ $s == status ]] || needs_root=1; done
  if ((needs_root)) && [[ $EUID -ne 0 ]]; then die "run as root (sudo -i)"; fi

  save_state
  ensure_tools "${plan[@]}"

  local i=0 n=${#plan[@]}
  for s in "${plan[@]}"; do
    i=$((i + 1))
    printf '\n%s[%d/%d] %s%s -- %s\n' "$C_B" "$i" "$n" "$s" "$C_0" "$(desc "$s")" >&2
    run_step "$s"
  done
  say "all requested steps finished"
}

main "$@"
