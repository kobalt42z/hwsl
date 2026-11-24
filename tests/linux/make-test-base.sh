#!/bin/bash
# Builds a STAND-IN base rootfs for CI/offline tests when the real Podman
# machine OS (quay.io/podman/machine-os) is not reachable: plain Fedora plus
# no-op stubs for the tools the real image ships (podman, sshd, systemctl...).
# Never ship an image built from this base.
#   tests/linux/make-test-base.sh <out.tar.zst> [engine] [fedora image]
set -euo pipefail
out="${1:?out.tar.zst}"; engine="${2:-podman}"; from="${3:-registry.fedoraproject.org/fedora:43}"
name="golden-test-base-$$"
"$engine" run --name "$name" "$from" bash -c '
for c in ps sshd ssh-keygen systemctl podman iptables; do
    command -v "$c" >/dev/null && continue
    printf "#!/bin/sh\nexit 0\n" > "/usr/local/sbin/$c"; chmod +x "/usr/local/sbin/$c"
done
[ -e /usr/sbin/sshd ] || ln -s /usr/local/sbin/sshd /usr/sbin/sshd
command -v su >/dev/null || { printf "#!/bin/sh\nexec runuser \"\$@\"\n" > /usr/local/bin/su; chmod +x /usr/local/bin/su; }
mkdir -p /etc/containers/registries.conf.d /etc/ssh/sshd_config.d
touch /etc/fstab /etc/ssh/sshd_config'
"$engine" export "$name" | zstd -q -T0 -o "$out"
"$engine" rm "$name" >/dev/null
echo "$out"
