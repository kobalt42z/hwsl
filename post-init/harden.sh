#!/bin/bash
# -----------------------------------------------------------------------------
# harden.sh - apply the golden-image hardening to a Podman WSL machine distro.
#
# Run as root, AFTER `podman machine init --image <golden tar>`:
#
#   wsl -d podman-machine-default -u root -- \
#       /usr/local/libexec/golden-image/harden.sh --win-user jdoe
#
# Idempotent: running it again produces the same files and the same manifest.
#
# Why post-init and not only at build time: `podman machine init` (5.8.9,
# pkg/machine/wsl/machine.go) OVERWRITES /etc/wsl.conf, /etc/containers/
# containers.conf and registries.conf.d/999-podman-machine.conf, and APPENDS
# to /etc/sudoers and /etc/fstab. Anything baked into the image in those files
# is lost or weakened, so this script re-applies it on top of what Podman wrote
# without dropping the keys Podman relies on. See docs/podman-provisioning.md.
#
# Stages:
#   --stage build      run inside the Containerfile: image-wide settings only
#                      (no user, no fstab, no sudoers, no manifest)
#   --stage post-init  (default) full hardening + manifest
#   --verify           only check the files against the manifest (exit 0/1)
# -----------------------------------------------------------------------------
set -euo pipefail
umask 022

readonly GI_DIR=/etc/golden-image
readonly GI_LIBEXEC=/usr/local/libexec/golden-image
readonly MANIFEST="$GI_DIR/manifest.sha256"
readonly FSTAB_BEGIN="# BEGIN golden-image managed drvfs mounts (do not edit)"
readonly FSTAB_END="# END golden-image managed drvfs mounts"

STAGE=post-init
CONFIG="$GI_DIR/config.env"
WIN_USER=""
PROFILE_PATH=""
APPDATA_PATH=""
VS_ROOT=""
SKIP_VS=false
SKIP_NUGET_FALLBACK=false
FORCE=false
DRY_RUN=false
EXTRA_MOUNTS=()
NO_WIN_MOUNTS=false
FROM_HOST_ENV=false
MOUNT_SOURCE=manual
readonly HOST_ENV="$GI_DIR/host.env"

log()  { printf '[harden] %s\n' "$*" >&2; }
# same_file A B - true if both exist with identical content (no diffutils needed)
same_file() { [[ -f "$1" && -f "$2" ]] && [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]; }
die()  { printf '[harden] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: harden.sh (--win-user NAME | --profile 'C:\Users\X' | --from-host-env | --no-windows-mounts) [options]

Mount source (post-init, pick one):
  --win-user NAME          Windows user name (used for C:\Users\NAME defaults)
  --profile 'C:\Users\X'   see below; the user name is derived from it
  --from-host-env          reuse the settings saved in /etc/golden-image/host.env
                           by an earlier run (used by the boot-time self-heal)
  --no-windows-mounts      fail closed: harden everything, mount no Windows folder

Options:
  --profile 'C:\Users\X'   Exact %USERPROFILE% (case matters: Podman maps
                           C:\Users\X to /mnt/c/Users/X verbatim)
  --appdata 'C:\...\Roaming'  Exact %APPDATA% (default <profile>\AppData\Roaming)
  --vs-root 'C:\Program Files\Microsoft Visual Studio\18\Enterprise'
                           VS 2026 install root (default from VS_EDITION)
  --skip-vs                Do not mount the VS tools folders
  --skip-nuget-fallback    Do not mount the VS NuGet fallback folder
  --extra-mount 'C:\path:ro|rw'  Extra approved mount (repeatable)
  --config FILE            Config file (default /etc/golden-image/config.env)
  --stage build|post-init  See header
  --verify                 Check files against the manifest and exit
  --force                  Run post-init even if the Podman marker is missing
  --dry-run                Print the generated files, change nothing
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --win-user)            WIN_USER="${2:?}"; shift 2 ;;
        --profile)             PROFILE_PATH="${2:?}"; shift 2 ;;
        --appdata)             APPDATA_PATH="${2:?}"; shift 2 ;;
        --vs-root)             VS_ROOT="${2:?}"; shift 2 ;;
        --skip-vs)             SKIP_VS=true; shift ;;
        --skip-nuget-fallback) SKIP_NUGET_FALLBACK=true; shift ;;
        --extra-mount)         EXTRA_MOUNTS+=("${2:?}"); shift 2 ;;
        --no-windows-mounts)   NO_WIN_MOUNTS=true; shift ;;
        --from-host-env)       FROM_HOST_ENV=true; shift ;;
        --mount-source)        MOUNT_SOURCE="${2:?}"; shift 2 ;;
        --config)              CONFIG="${2:?}"; shift 2 ;;
        --stage)               STAGE="${2:?}"; shift 2 ;;
        --verify)              STAGE=verify; shift ;;
        --force)               FORCE=true; shift ;;
        --dry-run)             DRY_RUN=true; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root (wsl -d <distro> -u root -- ...)"
[[ -r "$CONFIG" ]] || die "config not found: $CONFIG"
# shellcheck source=../config/golden-image.env
source "$CONFIG"

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

# write_file PATH MODE CONTENT - atomic, only touches the file if it changed
write_file() {
    local path="$1" mode="$2" content="$3" tmp
    if $DRY_RUN; then
        printf '\n===== %s (mode %s) =====\n%s\n' "$path" "$mode" "$content"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    tmp="$(mktemp "${path}.XXXXXX")"
    printf '%s\n' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    chown root:root "$tmp"
    if same_file "$tmp" "$path"; then
        rm -f "$tmp"
    else
        mv -f "$tmp" "$path"
        log "wrote $path"
    fi
}

# Windows path -> path inside the distro, exactly like Podman's
# specgen.ConvertWinMountPath: drive letter lower-cased, rest kept verbatim.
#   C:\Users\Jo\source\repos -> /mnt/c/Users/Jo/source/repos
win_to_wsl() {
    local p="$1"
    p="${p%\\}"
    [[ "$p" =~ ^([A-Za-z]):(.*)$ ]] || die "not a drive path: $1"
    local drive="${BASH_REMATCH[1],,}" rest="${BASH_REMATCH[2]}"
    rest="${rest//\\//}"
    printf '/mnt/%s%s' "$drive" "$rest"
}

# Windows path -> drvfs device string with forward slashes: C:/Users/Jo/...
win_to_drvfs_dev() {
    local p="${1%\\}"
    printf '%s' "${p//\\//}"
}

# fstab field escaping (getmntent/libmount octal escapes)
fstab_escape() {
    local s="$1"
    s="${s//\\/\\134}"
    s="${s// /\\040}"
    s="${s//$'\t'/\\011}"
    printf '%s' "$s"
}

# ini_merge FILE - merge "section.key=value" lines from stdin into an INI file.
# Existing sections/keys are kept in order; given keys are overwritten.
ini_merge() {
    local file="$1"
    awk -v overrides="$(cat)" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        BEGIN {
            n = split(overrides, ov, "\n")
            for (i = 1; i <= n; i++) {
                if (ov[i] == "") continue
                dot = index(ov[i], "."); eq = index(ov[i], "=")
                s = substr(ov[i], 1, dot - 1); k = substr(ov[i], dot + 1, eq - dot - 1)
                v = substr(ov[i], eq + 1)
                if (!(s in want_sec)) { want_sec[s] = 1; worder[++nws] = s }
                want[s, k] = v; wk[s] = wk[s] SUBSEP k
            }
            sec = ""
        }
        /^[ \t]*\[[^]]+\][ \t]*$/ {
            line = trim($0); sec = substr(line, 2, length(line) - 2)
            if (!(sec in have_sec)) { have_sec[sec] = 1; order[++ns] = sec }
            next
        }
        /^[ \t]*[#;]/ || /^[ \t]*$/ { next }
        {
            eq = index($0, "=")
            if (eq == 0) next
            k = trim(substr($0, 1, eq - 1)); v = trim(substr($0, eq + 1))
            if (!((sec, k) in val)) keys[sec] = keys[sec] SUBSEP k
            val[sec, k] = v
        }
        END {
            for (i = 1; i <= nws; i++) {
                s = worder[i]
                if (!(s in have_sec)) { have_sec[s] = 1; order[++ns] = s }
                m = split(wk[s], ks, SUBSEP)
                for (j = 2; j <= m; j++) {
                    if (!((s, ks[j]) in val)) keys[s] = keys[s] SUBSEP ks[j]
                    val[s, ks[j]] = want[s, ks[j]]
                }
            }
            print "# Managed by golden-image harden.sh (merged with Podman provisioning)."
            for (i = 1; i <= ns; i++) {
                s = order[i]
                if (s == "") continue
                printf "[%s]\n", s
                m = split(keys[s], ks, SUBSEP)
                for (j = 2; j <= m; j++) printf "%s=%s\n", ks[j], val[s, ks[j]]
                print ""
            }
        }
    ' "$file"
}

# ----------------------------------------------------------------------------
# 2. /etc/wsl.conf
# ----------------------------------------------------------------------------
apply_wsl_conf() {
    local stage="$1" existing=/etc/wsl.conf src
    src="$(mktemp)"
    [[ -f $existing ]] && cat "$existing" > "$src"
    local overrides
    overrides="boot.systemd=${WSL_BOOT_SYSTEMD}
automount.enabled=false
automount.mountFsTab=true
interop.enabled=false
interop.appendWindowsPath=false"
    if [[ $stage == post-init ]]; then
        # At build time the user does not exist yet; Podman writes
        # [user] default=user itself during init.
        overrides+="
user.default=${MACHINE_USER}"
    fi
    write_file /etc/wsl.conf 0644 "$(ini_merge "$src" <<<"$overrides")"
    rm -f "$src"
}

# ----------------------------------------------------------------------------
# 3. /etc/fstab
# ----------------------------------------------------------------------------
fstab_line() {
    # fstab_line WINPATH ro|rw
    local win="$1" mode="$2" target dev opts
    target="$(win_to_wsl "$win")"
    dev="$(win_to_drvfs_dev "$win")"
    opts="${mode},noatime,nosuid,nodev,nofail,uid=${MACHINE_UID},gid=${MACHINE_UID}"
    if [[ $mode == rw ]]; then
        # metadata: keep Linux permission bits (git exec bit, chmod in builds)
        opts+=",metadata,umask=022,fmask=011"
    else
        opts+=",umask=022"
    fi
    printf '%s %s drvfs %s 0 0' "$(fstab_escape "$dev")" "$(fstab_escape "$target")" "$opts"
}

# Saved mount settings, so the boot-time self-heal can re-apply exactly what
# the last explicit (or auto-detected) run used. Part of the manifest.
load_host_env() {
    [[ -f $HOST_ENV ]] || die "no $HOST_ENV to reuse"
    # shellcheck source=/dev/null
    source "$HOST_ENV"
    PROFILE_PATH="${H_PROFILE:-}"; APPDATA_PATH="${H_APPDATA:-}"; VS_ROOT="${H_VS_ROOT:-}"
    SKIP_VS="${H_SKIP_VS:-false}"; SKIP_NUGET_FALLBACK="${H_SKIP_NUGET_FALLBACK:-false}"
    NO_WIN_MOUNTS="${H_NO_WIN_MOUNTS:-false}"; MOUNT_SOURCE="${H_MOUNT_SOURCE:-manual}"
    EXTRA_MOUNTS=()
    local IFS=';'
    if [[ -n ${H_EXTRA_MOUNTS:-} ]]; then read -r -a EXTRA_MOUNTS <<<"$H_EXTRA_MOUNTS"; fi
}

save_host_env() {
    local extra="" m
    for m in "${EXTRA_MOUNTS[@]}"; do extra+="${extra:+;}$m"; done
    write_file "$HOST_ENV" 0644 "# Written by harden.sh - mount settings of the last run.
H_MOUNT_SOURCE=$(printf '%q' "$MOUNT_SOURCE")
H_NO_WIN_MOUNTS=$(printf '%q' "$NO_WIN_MOUNTS")
H_PROFILE=$(printf '%q' "$PROFILE_PATH")
H_APPDATA=$(printf '%q' "$APPDATA_PATH")
H_VS_ROOT=$(printf '%q' "$VS_ROOT")
H_SKIP_VS=$(printf '%q' "$SKIP_VS")
H_SKIP_NUGET_FALLBACK=$(printf '%q' "$SKIP_NUGET_FALLBACK")
H_EXTRA_MOUNTS=$(printf '%q' "$extra")"
}

apply_fstab() {
    local entries=()
    if $NO_WIN_MOUNTS; then
        log "no Windows folders are mounted (--no-windows-mounts)"
    else
        if [[ -z $WIN_USER && -n $PROFILE_PATH ]]; then
            WIN_USER="${PROFILE_PATH%\\}"; WIN_USER="${WIN_USER##*\\}"
        fi
        [[ -n $WIN_USER ]] || die "--win-user, --profile, --from-host-env or --no-windows-mounts is required"
        [[ $WIN_USER =~ ^[A-Za-z0-9._\ -]+$ ]] || die "unexpected characters in the Windows user name: $WIN_USER"
        PROFILE_PATH="${PROFILE_PATH:-C:\\Users\\$WIN_USER}"
        APPDATA_PATH="${APPDATA_PATH:-$PROFILE_PATH\\AppData\\Roaming}"
        VS_ROOT="${VS_ROOT:-C:\\Program Files\\Microsoft Visual Studio\\${VS_MAJOR_FOLDER}\\${VS_EDITION}}"
    fi
    local profile="$PROFILE_PATH" appdata="$APPDATA_PATH" vsroot="$VS_ROOT"

    # "WINPATH|mode" - the approved list, in a fixed order
    if ! $NO_WIN_MOUNTS; then
    entries=(
        "$profile\\source\\repos|rw"
        "$profile\\vsdbg|rw"
        "$profile\\.nuget\\packages|ro"
        "$appdata\\Microsoft\\UserSecrets|ro"
        "$appdata\\ASP.NET\\Https|ro"
    )
    if ! $SKIP_VS; then
        local sub subs
        IFS=';' read -r -a subs <<<"$VS_RO_SUBPATHS"
        for sub in "${subs[@]}"; do
            [[ -n $sub ]] && entries+=("$vsroot\\$sub|ro")
        done
    fi
    if ! $SKIP_NUGET_FALLBACK && [[ -n $NUGET_FALLBACK_PATH ]]; then
        entries+=("$NUGET_FALLBACK_PATH|ro")
    fi
    local m
    for m in "${EXTRA_MOUNTS[@]}"; do
        [[ $m =~ ^(.+):(ro|rw)$ ]] || die "--extra-mount must be 'C:\\path:ro' or ':rw': $m"
        entries+=("${BASH_REMATCH[1]}|${BASH_REMATCH[2]}")
    done
    fi

    local block="$FSTAB_BEGIN" e targets=()
    for e in "${entries[@]}"; do
        block+=$'\n'"$(fstab_line "${e%|*}" "${e##*|}")"
        targets+=("$(win_to_wsl "${e%|*}")")
    done
    block+=$'\n'"$FSTAB_END"

    # Keep every line Podman (or the base image) wrote - notably the
    # podman-user.sock bind mount - but drop an old managed block and any
    # other drvfs/9p mount, which would widen the approved mount list.
    local kept=""
    if [[ -f /etc/fstab ]]; then
        kept="$(awk -v b="$FSTAB_BEGIN" -v e="$FSTAB_END" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            skip { next }
            $3 == "drvfs" || $3 == "9p" { next }
            { print }
        ' /etc/fstab)"
    fi

    write_file /etc/fstab 0644 "${kept:+$kept$'\n'}$block"
    $DRY_RUN || save_host_env

    if ! $DRY_RUN; then
        local t
        for t in "${targets[@]}"; do mkdir -p -- "$t"; done
    fi
}

# ----------------------------------------------------------------------------
# 4. container configuration
# ----------------------------------------------------------------------------
apply_registries() {
    local ah="$ARTIFACTORY_HOST" prefix repo body
    body="# Managed by golden-image harden.sh - do not edit.
unqualified-search-registries = [\"${ah}\"]
short-name-mode = \"enforcing\"
"
    for pair in "docker.io:$ARTIFACTORY_REPO_DOCKERHUB" "quay.io:$ARTIFACTORY_REPO_QUAY" \
                "ghcr.io:$ARTIFACTORY_REPO_GHCR" "mcr.microsoft.com:$ARTIFACTORY_REPO_MCR"; do
        prefix="${pair%%:*}"; repo="${pair#*:}"
        case "$REGISTRY_MODE" in
            redirect)
                body+="
[[registry]]
prefix = \"${prefix}\"
location = \"${ah}/${repo}\"
"
                ;;
            block)
                body+="
[[registry]]
prefix = \"${prefix}\"
location = \"${prefix}\"
blocked = true
"
                ;;
            *) die "REGISTRY_MODE must be redirect or block" ;;
        esac
    done
    # registry-1.docker.io is what docker.io resolves to; cover it explicitly.
    body+="
[[registry]]
prefix = \"registry-1.docker.io\"
location = \"registry-1.docker.io\"
blocked = true
"
    write_file /etc/containers/registries.conf 0644 "$body"

    # Podman init writes unqualified-search-registries=["docker.io"] into this
    # drop-in, which would override the main file. Replace it (and keep the
    # same name so a later re-init is visible as a manifest mismatch).
    write_file /etc/containers/registries.conf.d/999-podman-machine.conf 0644 \
"# Managed by golden-image harden.sh. Podman init writes docker.io here.
unqualified-search-registries = [\"${ah}\"]"

    if [[ $REGISTRY_MODE == block ]]; then
        # Short-name aliases (containers-common) resolve e.g. "alpine" to
        # docker.io/library/alpine, which is blocked in this mode.
        local sn=/etc/containers/registries.conf.d/000-shortnames.conf
        if [[ -f $sn ]]; then
            write_file "$sn" 0644 "# aliases removed by golden-image (REGISTRY_MODE=block)"
        fi
    fi
}

apply_containers_conf() {
    local caps="" c
    for c in $DEFAULT_CAPABILITIES; do caps+="  \"${c}\","$'\n'; done
    # A drop-in instead of rewriting containers.conf: Podman init overwrites
    # /etc/containers/containers.conf with cgroup_manager=cgroupfs and
    # firewall_driver=iptables, which it needs on WSL. Drop-ins are applied
    # after the main file, so both survive.
    write_file /etc/containers/containers.conf.d/50-golden-image.conf 0644 \
"# Managed by golden-image harden.sh - do not edit.
[containers]
default_capabilities = [
${caps%$'\n'}
]
log_driver = \"journald\"

[engine]
events_logger = \"journald\""
}

# ----------------------------------------------------------------------------
# 1. users and privilege
# ----------------------------------------------------------------------------
apply_privilege() {
    id "$MACHINE_USER" >/dev/null 2>&1 || die "user '$MACHINE_USER' missing - run podman machine init first"
    [[ "$(id -u "$MACHINE_USER")" == "$MACHINE_UID" ]] || die "'$MACHINE_USER' is not UID $MACHINE_UID"

    if [[ $RESTRICT_SUDO != true ]]; then
        log "RESTRICT_SUDO=false: leaving Podman's wheel NOPASSWD rule in place"
        return 0
    fi

    # Root-owned, argument-free helper (baked into the image by build/). It is
    # the only thing "user" may run through sudo: Podman's
    # /etc/profile.d/enterns.sh calls enterns on login, which needs root to
    # nsenter into the namespace where Podman's systemd runs.
    [[ -x $GI_LIBEXEC/enterns-user && -f $GI_LIBEXEC/enterns ]] \
        || die "$GI_LIBEXEC/enterns-user missing - image not built from build/?"
    # Replace Podman's enterns (a provisioning script, not a Podman binary).
    write_file /usr/local/bin/enterns 0755 "$(cat "$GI_LIBEXEC/enterns")"

    local rule="Defaults:${MACHINE_USER} !requiretty
${MACHINE_USER} ALL=(root) NOPASSWD: ${GI_LIBEXEC}/enterns-user \"\""
    write_file /etc/sudoers.d/10-golden-image 0440 "# Managed by golden-image harden.sh - do not edit.
$rule"

    if ! $DRY_RUN; then
        # Podman init appends "%wheel ALL=(ALL) NOPASSWD: ALL" to /etc/sudoers.
        local tmp
        tmp="$(mktemp)"
        sed -E '/^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+NOPASSWD:[[:space:]]*ALL[[:space:]]*$/d' \
            /etc/sudoers > "$tmp"
        if ! same_file "$tmp" /etc/sudoers; then
            visudo -cqf "$tmp" || die "sudoers would be invalid"
            install -m 0440 -o root -g root "$tmp" /etc/sudoers
            log "removed wheel NOPASSWD rule from /etc/sudoers"
        fi
        rm -f "$tmp"
        visudo -cq || die "sudoers check failed"

        if [[ $REMOVE_USER_FROM_WHEEL == true ]] && id -nG "$MACHINE_USER" | tr ' ' '\n' | grep -qx wheel; then
            gpasswd -d "$MACHINE_USER" wheel >/dev/null
            log "removed $MACHINE_USER from wheel"
        fi
    fi
}

# sshd: Podman needs key auth for "user" and root (rootful mode / win-sshproxy).
apply_sshd() {
    write_file /etc/ssh/sshd_config.d/50-golden-image.conf 0600 "# Managed by golden-image harden.sh - do not edit.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
AllowTcpForwarding local
X11Forwarding no
AllowUsers ${MACHINE_USER} root"
}

# ----------------------------------------------------------------------------
# Drop-in directories: files that were not in the image at build time and are
# not written by this script are moved to a quarantine folder (a new
# sudoers.d or registries.conf.d file is the easiest way around the policy).
# ----------------------------------------------------------------------------
readonly DROPIN_DIRS=(/etc/sudoers.d /etc/containers/registries.conf.d /etc/containers/containers.conf.d)
readonly BASELINE="$GI_DIR/dropin-baseline"
readonly QUARANTINE=/var/lib/golden-image/quarantine

record_dropin_baseline() {
    local d body=""
    for d in "${DROPIN_DIRS[@]}"; do
        [[ -d $d ]] || continue
        body+="$(find "$d" -maxdepth 1 -type f | LC_ALL=C sort)"$'\n'
    done
    # files harden.sh itself manages are always allowed
    body+="/etc/sudoers.d/10-golden-image
/etc/containers/registries.conf.d/999-podman-machine.conf
/etc/containers/containers.conf.d/50-golden-image.conf"
    write_file "$BASELINE" 0644 "$(printf '%s\n' "$body" | sed '/^$/d' | LC_ALL=C sort -u)"
}

quarantine_unknown_dropins() {
    [[ -f $BASELINE ]] || { log "no $BASELINE; skipping drop-in quarantine"; return 0; }
    local d f dest
    for d in "${DROPIN_DIRS[@]}"; do
        [[ -d $d ]] || continue
        while IFS= read -r f; do
            grep -qxF -- "$f" "$BASELINE" && continue
            if $DRY_RUN; then log "would quarantine $f"; continue; fi
            dest="$QUARANTINE/$(date -u +%Y%m%dT%H%M%SZ)$f"
            mkdir -p "$(dirname "$dest")"
            mv -f -- "$f" "$dest"
            log "QUARANTINED unapproved drop-in $f -> $dest"
        done < <(find "$d" -maxdepth 1 -type f | LC_ALL=C sort)
    done
}

# ----------------------------------------------------------------------------
# 7. tamper evidence
# ----------------------------------------------------------------------------
manifest_files() {
    local f
    local globs=(
        /etc/wsl.conf
        /etc/fstab
        /etc/containers/registries.conf
        /etc/containers/registries.conf.d/*
        /etc/containers/containers.conf
        /etc/containers/containers.conf.d/*
        /etc/containers/podman-machine
        /etc/sudoers
        /etc/sudoers.d/*
        /etc/pki/ca-trust/source/anchors/*
        /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
        /etc/ssh/sshd_config.d/50-golden-image.conf
        /etc/yum.repos.d/*
        /usr/local/bin/enterns
        /etc/systemd/system/golden-image-selfheal.service
        /etc/systemd/system/multi-user.target.wants/golden-image-selfheal.service
        "$GI_LIBEXEC"/*
        "$GI_DIR"/version
        "$GI_DIR"/config.env
        "$HOST_ENV"
        "$BASELINE"
    )
    shopt -s nullglob
    for f in "${globs[@]}"; do
        if [[ -f $f ]]; then printf '%s\n' "$f"; fi
    done | LC_ALL=C sort -u
    shopt -u nullglob
}

write_manifest() {
    local body
    body="$(manifest_files | while read -r f; do sha256sum -- "$f"; done)"
    write_file "$MANIFEST" 0444 "$body"
}

verify_manifest() {
    [[ -f $MANIFEST ]] || die "no manifest at $MANIFEST"
    local rc=0 expected actual
    sha256sum --quiet -c "$MANIFEST" || rc=1
    expected="$(awk '{print $2}' "$MANIFEST" | LC_ALL=C sort -u)"
    actual="$(manifest_files)"
    if [[ "$expected" != "$actual" ]]; then
        log "file set differs from manifest:"
        comm -3 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") \
            | sed 's/^\t/  new: /; t; s/^/  missing: /' >&2
        rc=1
    fi
    [[ $rc -eq 0 ]] && log "manifest OK ($(wc -l < "$MANIFEST") files)"
    return $rc
}

# ----------------------------------------------------------------------------
main() {
    case "$STAGE" in
        verify)
            verify_manifest
            ;;
        build)
            apply_wsl_conf build
            apply_registries
            apply_containers_conf
            apply_sshd
            record_dropin_baseline
            ;;
        post-init)
            if [[ ! -f /etc/containers/podman-machine ]] && ! $FORCE; then
                die "/etc/containers/podman-machine missing: run podman machine init first (or --force)"
            fi
            if $FROM_HOST_ENV; then load_host_env; fi
            apply_wsl_conf post-init
            apply_fstab
            apply_registries
            apply_containers_conf
            apply_privilege
            apply_sshd
            quarantine_unknown_dropins
            $DRY_RUN || write_manifest
            log "done. Restart the machine: podman machine stop; podman machine start"
            ;;
        *) die "unknown stage: $STAGE" ;;
    esac
}

main
