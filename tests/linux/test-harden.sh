#!/bin/bash
# Offline test of the golden tar + harden.sh on Linux (no Windows needed).
#   tests/linux/test-harden.sh out/podman-wsl-golden-<ver>.tar.zst [docker|podman]
# Imports the tar as a container image (like `wsl --import`), replays Podman's
# provisioning, runs harden.sh, and asserts the resulting files.
set -euo pipefail
tarball="${1:?golden tar.zst}"; engine="${2:-podman}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
img="localhost/golden-under-test:latest"
zstd -dc "$tarball" | "$engine" import - "$img" >/dev/null

"$engine" run --rm --network=none -v "$here:/t:ro" "$img" /bin/bash -euo pipefail -c '
H=/usr/local/libexec/golden-image/harden.sh
fail() { echo "FAIL: $*"; exit 1; }
ok()   { echo "ok   $*"; }

# image-level state
grep -q "^enabled=false" /etc/wsl.conf && ok "image wsl.conf has automount/interop off" || fail "image wsl.conf"
[ "$(ls /etc/yum.repos.d)" = "golden-mirror.repo" ] && ok "only internal dnf repo" || fail "yum.repos.d: $(ls /etc/yum.repos.d)"
grep -q "Test Corp Root\|BEGIN CERTIFICATE" /etc/pki/ca-trust/source/anchors/*.crt && ok "CA anchor present" || fail "CA"
awk "/BEGIN CERT/{n++} END{exit !(n>0)}" /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem && ok "CA bundle extracted" || fail "bundle"

$H --win-user jo 2>/dev/null && fail "harden must refuse before podman init" || ok "refuses without podman marker"

bash /t/simulate-podman-init.sh >/dev/null

$H --win-user "Jo Doe" --profile "C:\\Users\\Jo Doe" \
   --vs-root "C:\\Program Files\\Microsoft Visual Studio\\18\\Enterprise"
cp /etc/golden-image/manifest.sha256 /tmp/m1

echo "--- wsl.conf";   cat /etc/wsl.conf
echo "--- fstab";      cat /etc/fstab
echo "--- registries"; cat /etc/containers/registries.conf /etc/containers/registries.conf.d/999-podman-machine.conf
echo "--- containers.conf.d"; cat /etc/containers/containers.conf.d/50-golden-image.conf
echo "--- sudoers.d";  cat /etc/sudoers.d/10-golden-image
echo "---"

grep -q "^default=user" /etc/wsl.conf && ok "[user] default=user kept" || fail "wsl user"
grep -q "^systemd=false" /etc/wsl.conf && ok "boot.systemd=false (Podman conflict switch)" || fail "systemd"
grep -q "^appendWindowsPath=false" /etc/wsl.conf || fail "appendWindowsPath"
grep -q "podman-user.sock none noauto,user,bind" /etc/fstab && ok "Podman fstab bind line kept" || fail "podman bind line lost"
grep -q "^C:/Users/Jo\\\\040Doe/source/repos /mnt/c/Users/Jo\\\\040Doe/source/repos drvfs rw," /etc/fstab && ok "repos drvfs line escaped" || fail "repos line"
grep -q "^C:/Program\\\\040Files/Microsoft\\\\040Visual\\\\040Studio/18/Enterprise/MSBuild/Sdks/Microsoft.Docker.Sdk/tools " /etc/fstab && ok "VS tools line" || fail "vs line"
[ "$(awk "\$3==\"drvfs\"" /etc/fstab | wc -l)" = 8 ] && ok "8 approved drvfs mounts" || fail "drvfs count $(awk "\$3==\"drvfs\"" /etc/fstab | wc -l)"
[ -d "/mnt/c/Users/Jo Doe/vsdbg" ] && ok "mount points created" || fail "mountpoints"
grep -q "cgroup_manager = \"cgroupfs\"" /etc/containers/containers.conf && ok "Podman containers.conf untouched" || fail "containers.conf"
grep -q "artifactory.example.com/mcr-remote" /etc/containers/registries.conf && ok "mcr redirected" || fail "mcr"
grep -q "^unqualified.*docker.io" /etc/containers/registries.conf.d/999-podman-machine.conf && fail "999 drop-in still docker.io" || ok "999 drop-in overridden"
grep -Eq "^%wheel.*NOPASSWD" /etc/sudoers && fail "wheel NOPASSWD still present" || ok "wheel NOPASSWD removed"
id -nG user | grep -qw wheel && fail "user still in wheel" || ok "user removed from wheel"
visudo -c >/dev/null && ok "sudoers valid" || fail "visudo"
sudo -l -U user | grep -q "/usr/local/libexec/golden-image/enterns-user" && ok "sudo -l: only enterns-user" || fail "sudo -l"
sudo -l -U user | grep -Eq "\(ALL\) NOPASSWD: ALL|\(ALL\) ALL" && fail "user still has broad sudo" || ok "no broad sudo"
runuser -u user -- sudo -n /bin/true 2>/dev/null && fail "user can sudo /bin/true" || ok "user cannot sudo arbitrary commands"
runuser -u user -- sudo -n /usr/local/libexec/golden-image/enterns-user extra 2>/dev/null && fail "args accepted" || ok "helper rejects arguments"
grep -q "disabled by policy" /usr/local/bin/enterns && ok "enterns replaced" || fail "enterns"

$H --verify && ok "verify passes" || fail "verify"

# idempotent
$H --win-user "Jo Doe" --profile "C:\\Users\\Jo Doe" --vs-root "C:\\Program Files\\Microsoft Visual Studio\\18\\Enterprise" 2>/dev/null
[ "$(sha256sum < /tmp/m1)" = "$(sha256sum < /etc/golden-image/manifest.sha256)" ] && ok "second run: identical manifest" || { cat /tmp/m1 /etc/golden-image/manifest.sha256; fail "not idempotent"; }
[ "$(awk "\$3==\"drvfs\"" /etc/fstab | wc -l)" = 8 ] || fail "fstab grew on rerun"

# tamper detection
echo "# tamper" >> /etc/wsl.conf
$H --verify 2>/dev/null && fail "verify missed wsl.conf edit" || ok "wsl.conf edit detected"
sed -i "/# tamper/d" /etc/wsl.conf
$H --verify 2>/dev/null || fail "restore"
echo "user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-evil; chmod 440 /etc/sudoers.d/99-evil
$H --verify 2>/dev/null && fail "verify missed new sudoers.d file" || ok "new sudoers.d file detected"
rm /etc/sudoers.d/99-evil
echo "C: /mnt/c drvfs rw 0 0" >> /etc/fstab
$H --verify 2>/dev/null && fail "fstab edit missed" || ok "fstab edit detected"
$H --win-user "Jo Doe" --profile "C:\\Users\\Jo Doe" --vs-root "C:\\Program Files\\Microsoft Visual Studio\\18\\Enterprise" 2>/dev/null
grep -q "^C: /mnt/c" /etc/fstab && fail "rogue drvfs line survived re-harden" || ok "re-harden removes rogue drvfs line"
[ "$(sha256sum < /tmp/m1)" = "$(sha256sum < /etc/golden-image/manifest.sha256)" ] && ok "re-harden restores manifest" || fail "manifest differs after re-harden"
echo ALL-PASSED
'
