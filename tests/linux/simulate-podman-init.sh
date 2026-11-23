#!/bin/bash
# Replays, inside a container made from the golden tar, the file changes that
# `podman machine init` (Podman 5.8.9, WSL provider) makes in the distro:
# pkg/machine/wsl/machine.go configureSystem/configureBindMounts/
# installScripts/createKeys/writeWslConf and declares.go. Commands are copied
# from those constants; systemd/sshd specifics are reduced to their file effects.
# Used by tests/linux/test-harden.sh. Not for real machines.
set -euo pipefail
USER_NAME=user
DIST=podman-machine-default

rpm --restore shadow-utils 2>/dev/null || true
mkdir -p /usr/local/bin
grep -q "Port 50000" /etc/ssh/sshd_config 2>/dev/null || echo "Port 50000" >> /etc/ssh/sshd_config

# configServices (subset with file effects)
mkdir -p /etc/systemd/system/systemd-sysusers.service.d/
echo CREATE_MAIL_SPOOL=no >> /etc/default/useradd
adduser -m "$USER_NAME" -G wheel
mkdir -p "/home/$USER_NAME/.config/systemd/$USER_NAME/"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config"

# sudoers
printf '%%wheel        ALL=(ALL)       NOPASSWD: ALL\n' >> /etc/sudoers
printf '[Service]\nLoadCredential=\n' > /etc/systemd/system/systemd-sysusers.service.d/override.conf

mkdir -p /var/lib/systemd/linger; touch "/var/lib/systemd/linger/$USER_NAME"

cat > /etc/containers/containers.conf <<'CC'
[containers]

[engine]
cgroup_manager = "cgroupfs"

# Using iptables until we fix nftables on WSL:
# https://github.com/containers/podman/issues/25201
[network]
firewall_driver="iptables"
CC
mkdir -p /etc/containers/registries.conf.d
echo 'unqualified-search-registries=["docker.io"]' > /etc/containers/registries.conf.d/999-podman-machine.conf
mkdir -p /etc/tmpfiles.d
echo "L+  /run/docker.sock   -    -    -     -   /run/user/1000/podman/podman.sock" > /etc/tmpfiles.d/podman-docker.conf
echo wsl > /etc/containers/podman-machine

# configureBindMounts (fstab + socket group drop-in)
echo "/run/user/1000/podman/podman.sock /mnt/wsl/podman-sockets/$DIST/podman-user.sock none noauto,user,bind,defaults 0 0" >> /etc/fstab
mkdir -p /etc/systemd/system/podman.socket.d
printf '\n[Socket]\nSocketMode=0660\nSocketGroup=wheel\n' > /etc/systemd/system/podman.socket.d/10-group.conf

# writeWslConf is called by changeDistUserModeNetworking -> overwrites wsl.conf
printf '[user]\ndefault=%s\n' "$USER_NAME" > /etc/wsl.conf

# installScripts: enterns (verbatim from declares.go)
cat > /usr/local/bin/enterns <<'EN'
#!/bin/bash
SYSDPID=`ps -eo cmd,pid | grep -m 1 ^/lib/systemd/systemd | awk '{print $2}'`
if [ ! -z "$SYSDPID" ] && [ "$SYSDPID" != "1" ]; then
        NSENTER=("nsenter" "-m" "-p" "-t" "$SYSDPID" "--wd=$PWD")

        if [ "$UID" != "0" ]; then
                NSENTER=("sudo" "${NSENTER[@]}")
                if [ "$#" != "0" ]; then
                        NSENTER+=("sudo" "-u" "$USER")
                else
                        NSENTER+=("su" "-l" "$USER")
                fi
        fi
        "${NSENTER[@]}" "$@"
fi
EN
chmod 755 /usr/local/bin/enterns

# createKeys
mkdir -p /root/.ssh "/home/$USER_NAME/.ssh"
echo "ssh-ed25519 AAAATEST test" >> /root/.ssh/authorized_keys
echo "ssh-ed25519 AAAATEST test" >> "/home/$USER_NAME/.ssh/authorized_keys"
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh"
echo "simulated podman machine init"
