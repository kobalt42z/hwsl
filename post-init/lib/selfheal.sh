#!/bin/bash
# -----------------------------------------------------------------------------
# selfheal.sh - boot-time enforcement of the golden-image hardening.
#
# Started by golden-image-selfheal.service inside Podman's systemd (every
# `podman machine start`). The unit is baked into the image, and Podman's
# `machine init` does not remove it, so it also covers a machine that was
# (re)created with `podman machine init` and never had harden.sh run on it.
#
#   1. manifest valid      -> nothing to repair; only live checks (step 4)
#   2. manifest missing    -> first boot after init: harden
#      manifest mismatch   -> tampering: log a REPAIR record, then harden
#   3. mount settings      -> reuse /etc/golden-image/host.env if present,
#                             else detect the owner's Windows profile (below),
#                             else fail closed (no Windows folders mounted)
#   4. live enforcement    -> this boot may still run with Podman's wsl.conf
#                             (automount + interop on): unmount unapproved
#                             Windows mounts, mount the approved ones, and
#                             disable the WSL interop binfmt handler now.
#
# Profile detection: Podman writes the machine's public key into
# /home/user/.ssh/authorized_keys. The same key lives in the owner's profile at
# %USERPROFILE%\.local\share\containers\podman\machine\machine.pub
# (pkg/machine/env: GetSSHIdentityPath = <GetDataHome>/containers/podman/machine/<name>,
# DefaultIdentityName "machine"). C:\Users is mounted read-only for a moment,
# the profile whose key matches is the owner, then it is unmounted again.
# -----------------------------------------------------------------------------
set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

GI_DIR=/etc/golden-image
LIB=/usr/local/libexec/golden-image
HARDEN="$LIB/harden.sh"
LOG_DIR=/var/log/golden-image
REPAIRS="$LOG_DIR/repairs.log"
PROBE=/run/golden-image/probe

mkdir -p "$LOG_DIR" /run/golden-image
chmod 0755 "$LOG_DIR"
log() { printf '%s [selfheal] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_DIR/selfheal.log" >&2; }

# shellcheck source=/dev/null
source "$GI_DIR/config.env"

[[ -f /etc/containers/podman-machine ]] || { log "not a Podman machine (no marker); nothing to do"; exit 0; }
id "$MACHINE_USER" >/dev/null 2>&1 || { log "user $MACHINE_USER missing; nothing to do"; exit 0; }

probe_mount() {   # probe_mount 'C:\Windows\Path' dir
    mkdir -p "$2"
    mount -t drvfs "$1" "$2" -o ro,noexec,nosuid,nodev 2>/dev/null
}
probe_umount() { umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null; rmdir "$1" 2>/dev/null || true; }

# Prints: profile-folder-name (or nothing)
detect_profile() {
    local keys="/home/$MACHINE_USER/.ssh/authorized_keys" dir name found=""
    [[ -s $keys ]] || return 0
    probe_mount 'C:\Users' "$PROBE/users" || { log "could not mount C:\\Users for detection"; return 0; }
    for dir in "$PROBE/users"/*/; do
        name="$(basename "$dir")"
        local pub="$dir.local/share/containers/podman/machine/machine.pub"
        [[ -f $pub ]] || continue
        local blob
        blob="$(awk '{print $2}' "$pub" 2>/dev/null)"
        [[ -n $blob ]] || continue
        if awk -v b="$blob" '$2 == b {f=1} END {exit !f}' "$keys"; then
            if [[ -n $found ]]; then
                log "machine key found in more than one profile ($found, $name); refusing to guess"
                found=""; break
            fi
            found="$name"
        fi
    done
    local appdata_ok=false
    if [[ -n $found && -d "$PROBE/users/$found/AppData/Roaming" ]]; then appdata_ok=true; fi
    probe_umount "$PROBE/users"
    if [[ -n $found ]] && ! $appdata_ok; then
        log "profile $found has no AppData\\Roaming (redirected AppData?); use harden.sh --appdata"
    fi
    printf '%s' "$found"
}

# Prints: VS 2026 install root as a Windows path (or nothing)
detect_vs_root() {
    local base='C:\Program Files\Microsoft Visual Studio' ed pick=""
    probe_mount "$base" "$PROBE/vs" || return 0
    if [[ -d "$PROBE/vs/$VS_MAJOR_FOLDER/$VS_EDITION/Common7" ]]; then
        pick="$VS_EDITION"
    else
        for ed in Enterprise Professional Community; do
            if [[ -d "$PROBE/vs/$VS_MAJOR_FOLDER/$ed/Common7" ]]; then pick="$ed"; break; fi
        done
    fi
    probe_umount "$PROBE/vs"
    [[ -n $pick ]] && printf '%s\\%s\\%s' "$base" "$VS_MAJOR_FOLDER" "$pick"
}

nuget_fallback_exists() {
    local d="${NUGET_FALLBACK_PATH%\\*}" leaf="${NUGET_FALLBACK_PATH##*\\}" rc=1
    [[ -n $NUGET_FALLBACK_PATH ]] || return 1
    probe_mount "$d" "$PROBE/nuget" || return 1
    [[ -d "$PROBE/nuget/$leaf" ]] && rc=0
    probe_umount "$PROBE/nuget"
    return $rc
}

# --- 1/2: is a repair needed? -------------------------------------------------
reason=""
if [[ ! -f $GI_DIR/manifest.sha256 ]]; then
    reason="first boot after podman machine init (no manifest)"
else
    if ! verify_out="$("$HARDEN" --verify 2>&1)"; then
        reason="manifest mismatch"
        {
            printf '%s REPAIR manifest mismatch\n' "$(date -u +%FT%TZ)"
            printf '%s\n' "$verify_out" | sed 's/^/    /'
        } >> "$REPAIRS"
        chmod 0644 "$REPAIRS"
    fi
fi

# Saved settings with no mounts (detection failed earlier): try detection again.
if [[ -z $reason && -f $GI_DIR/host.env ]] && grep -q '^H_MOUNT_SOURCE=none$' "$GI_DIR/host.env"; then
    reason="retry Windows profile detection"
fi

# --- 3: harden ------------------------------------------------------------------
if [[ -n $reason ]]; then
    log "hardening: $reason"
    args=()
    if [[ -f $GI_DIR/host.env ]] && ! grep -q '^H_MOUNT_SOURCE=none$' "$GI_DIR/host.env"; then
        args=(--from-host-env)
    else
        profile="$(detect_profile)"
        if [[ -n $profile ]]; then
            args=(--profile "C:\\Users\\$profile" --mount-source detected)
            vs="$(detect_vs_root)"
            if [[ -n $vs ]]; then args+=(--vs-root "$vs"); else args+=(--skip-vs); fi
            nuget_fallback_exists || args+=(--skip-nuget-fallback)
            log "detected Windows profile C:\\Users\\$profile${vs:+, VS at $vs}"
        else
            args=(--no-windows-mounts --mount-source none)
            log "owner profile not detected: failing closed (no Windows folders mounted)"
        fi
    fi
    if ! "$HARDEN" "${args[@]}" >>"$LOG_DIR/selfheal.log" 2>&1; then
        log "harden.sh failed (see $LOG_DIR/selfheal.log)"
    fi
fi

# --- 4: live enforcement (this boot) -------------------------------------------
# Approved targets = the managed fstab block.
mapfile -t approved < <(sed -n '/^# BEGIN golden-image managed drvfs mounts/,/^# END golden-image/p' /etc/fstab \
    | awk '$3 == "drvfs" {print $2}' | while read -r t; do printf '%b\n' "$t"; done)
is_approved() { local a; for a in "${approved[@]}"; do [[ "$1" == "$a" ]] && return 0; done; return 1; }

while read -r _src tgt fstype _rest; do
    tgt="$(printf '%b' "$tgt")"
    case "$fstype" in 9p|drvfs|virtiofs) ;; *) continue ;; esac
    [[ $tgt == /mnt/* && $tgt != /mnt/wsl* ]] || continue
    is_approved "$tgt" && continue
    if umount "$tgt" 2>/dev/null || umount -l "$tgt" 2>/dev/null; then
        log "unmounted unapproved Windows mount $tgt"
    fi
done < <(tac /proc/self/mounts)

mount -a -t drvfs 2>>"$LOG_DIR/selfheal.log" || true

for f in /proc/sys/fs/binfmt_misc/WSLInterop*; do
    [[ -f $f ]] || continue
    if head -n1 "$f" | grep -qx enabled; then
        echo 0 > "$f" && log "disabled $(basename "$f") binfmt handler for this boot"
    fi
done
exit 0
