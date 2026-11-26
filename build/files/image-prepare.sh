#!/bin/bash
# Runs inside the Containerfile RUN step. Offline: never touches a network repo.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/golden-image/config.env
log() { printf '[image-prepare] %s\n' "$*"; }

chmod 0644 /etc/golden-image/config.env /etc/golden-image/version
chmod 0755 /usr/local/libexec/golden-image/*
chmod 0644 /etc/systemd/system/golden-image-selfheal.service
# Enable the boot-time self-heal. Podman's configServices only adds/removes
# its own links, so this one survives `podman machine init`.
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf ../golden-image-selfheal.service /etc/systemd/system/multi-user.target.wants/golden-image-selfheal.service
chmod 0644 "/etc/pki/ca-trust/source/anchors/${CA_NAME}.crt"

# 5. corporate root CA into the system trust store
update-ca-trust extract
grep -q "BEGIN CERTIFICATE" "/etc/pki/ca-trust/source/anchors/${CA_NAME}.crt"

# 6. dnf: internal mirror only
rm -f /etc/yum.repos.d/*.repo
install -m 0644 /tmp/golden-build/golden-mirror.repo /etc/yum.repos.d/golden-mirror.repo

# Tools Podman provisioning / runtime calls inside the distro
# (pkg/machine/wsl/machine.go, stubber.go, declares.go, usermodenet.go).
REQUIRED_CMDS=(sh bash tac rpm mkdir ln adduser useradd gpasswd chown chmod cat grep sed awk
               ps nsenter unshare nohup timeout tail touch mount umount sudo visudo
               sshd ssh-keygen systemctl podman sha256sum iptables update-ca-trust su)

# 6. remove tools not needed to run containers (if installed)
to_remove=()
for p in $REMOVE_PACKAGES; do
    rpm -q "$p" >/dev/null 2>&1 && to_remove+=("$p")
done
if (( ${#to_remove[@]} )); then
    log "removing: ${to_remove[*]}"
    dnf -y --disablerepo='*' \
        --setopt=protected_packages="${DNF_PROTECTED_PACKAGES// /,}" \
        --setopt=clean_requirements_on_remove=False \
        remove "${to_remove[@]}"
else
    log "none of REMOVE_PACKAGES is installed"
fi

missing=()
for c in "${REQUIRED_CMDS[@]}"; do
    command -v "$c" >/dev/null 2>&1 || [[ -x /usr/sbin/$c ]] || missing+=("$c")
done
if (( ${#missing[@]} )); then
    log "ERROR: commands Podman needs are missing after package removal: ${missing[*]}"
    exit 1
fi

dnf clean all >/dev/null 2>&1 || true
rm -rf /var/cache/dnf /var/cache/libdnf5 /var/log/dnf* /var/lib/dnf/history* 2>/dev/null || true
log "ok"
