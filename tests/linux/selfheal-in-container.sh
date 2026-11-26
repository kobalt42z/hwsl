#!/bin/bash
# Runs INSIDE a container made from the golden tar (see test-harden.sh).
# Exercises selfheal.sh with a fake drvfs: `mount -t drvfs 'C:\X' dir` is
# served from /fakec/X, so profile detection can be tested without Windows.
# shellcheck disable=SC2015  # "a && ok || fail" is the intended test idiom
set -euo pipefail
fail() { echo "FAIL: $*"; exit 1; }
ok()   { echo "ok   $*"; }
SH=/usr/local/libexec/golden-image/selfheal.sh
H=/usr/local/libexec/golden-image/harden.sh

cat > /usr/local/sbin/mount <<'M'
#!/bin/bash
if [ "${1:-}" = "-a" ]; then exit 0; fi
if [ "${1:-}" = "-t" ] && [ "${2:-}" = "drvfs" ]; then
    [ "${3:-}" = "-a" ] && exit 0
    src="${3//\\//}"; src="/fakec/${src#C:/}"
    [ -d "$src" ] || exit 32
    rmdir "$4" 2>/dev/null; ln -s "$src" "$4"; exit 0
fi
exec /usr/bin/mount "$@"
M
cat > /usr/local/sbin/umount <<'U'
#!/bin/bash
for a in "$@"; do t="$a"; done
if [ -L "$t" ]; then rm -f "$t"; exit 0; fi
exec /usr/bin/umount "$@"
U
chmod +x /usr/local/sbin/mount /usr/local/sbin/umount

[ -L /etc/systemd/system/multi-user.target.wants/golden-image-selfheal.service ] && ok "self-heal unit enabled in image" || fail "unit not enabled"

# --- fail closed: machine initialised, no Windows profile visible
bash /t/simulate-podman-init.sh >/dev/null
$SH 2>/dev/null
[ "$(awk '$3=="drvfs"' /etc/fstab | wc -l)" = 0 ] && ok "no profile detected -> no Windows mounts" || fail "mounts without profile"
grep -q '^H_MOUNT_SOURCE=none$' /etc/golden-image/host.env && ok "host.env records mount source none" || fail "host.env none"
grep -Eq "^%wheel.*NOPASSWD" /etc/sudoers && fail "sudo not hardened by self-heal" || ok "self-heal hardened sudoers on first boot"
$H --verify 2>/dev/null && ok "manifest valid after first boot" || fail "verify after first boot"

# --- profile appears (e.g. C:\Users became readable): next boot detects it
mkdir -p "/fakec/Users/Public" "/fakec/Users/Other/.local/share/containers/podman/machine" \
         "/fakec/Users/Jo Doe/.local/share/containers/podman/machine" "/fakec/Users/Jo Doe/AppData/Roaming" \
         "/fakec/Program Files/Microsoft Visual Studio/18/Professional/Common7"
echo "ssh-ed25519 AAAAOTHER other" > /fakec/Users/Other/.local/share/containers/podman/machine/machine.pub
echo "ssh-ed25519 AAAATEST jo"      > "/fakec/Users/Jo Doe/.local/share/containers/podman/machine/machine.pub"
$SH 2>/dev/null
grep -q '^C:/Users/Jo\\040Doe/source/repos ' /etc/fstab && ok "owner profile detected by machine key" || { cat /etc/fstab; fail "profile detection"; }
grep -q 'Visual\\040Studio/18/Professional/' /etc/fstab && ok "VS edition detected (Professional)" || fail "vs detection"
grep -q 'NuGetPackages' /etc/fstab && fail "missing NuGet fallback mounted" || ok "absent NuGet fallback skipped"
grep -q '^H_MOUNT_SOURCE=detected$' /etc/golden-image/host.env && ok "host.env records detected" || fail "host.env detected"
[ ! -e /run/golden-image/probe/users ] && ok "probe mount removed" || fail "probe left mounted"
$H --verify 2>/dev/null || fail "verify after detection"
cp /etc/golden-image/manifest.sha256 /tmp/m-detected

# --- normal boot: nothing to repair, no REPAIR record
$SH 2>/dev/null
[ ! -s /var/log/golden-image/repairs.log ] && ok "clean boot: no repair logged" || fail "spurious repair"

# --- tampering between boots is repaired and logged
echo "[interop]" >> /etc/wsl.conf; echo "enabled=true" >> /etc/wsl.conf
echo "user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-evil; chmod 440 /etc/sudoers.d/99-evil
$SH 2>/dev/null
grep -q "REPAIR manifest mismatch" /var/log/golden-image/repairs.log && ok "repair logged" || fail "no repair record"
[ "$(sha256sum < /tmp/m-detected)" = "$(sha256sum < /etc/golden-image/manifest.sha256)" ] || {
    cat /tmp/m-detected /etc/golden-image/manifest.sha256; fail "manifest differs after repair"; }
ok "wsl.conf restored to the approved content"
[ ! -e /etc/sudoers.d/99-evil ] && ls /var/lib/golden-image/quarantine/*/etc/sudoers.d/99-evil >/dev/null 2>&1 \
    && ok "rogue sudoers.d file quarantined" || fail "rogue file not quarantined"
grep -q "99-evil" /var/log/golden-image/repairs.log && ok "rogue file named in repair record" || fail "rogue file not in repair record"
echo ALL-PASSED
