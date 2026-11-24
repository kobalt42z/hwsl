# What Podman 5.8.9 does inside the WSL distro

Source read: `containers/podman` tag **v5.8.9** (latest 5.x release; 6.x exists but
is out of scope), `pkg/machine/wsl/{declares.go,machine.go,stubber.go,usermodenet.go}`,
`pkg/machine/ocipull/`, `pkg/machine/stdpull/`, `pkg/machine/shim/`, `pkg/specgen/winpath*.go`.
Re-check this list whenever `PODMAN_VERSION` changes.

## Image format (`podman machine init --image`)

| Input | Code path | What happens |
|---|---|---|
| empty / `docker://…` | `ocipull.NewOCIArtifactPull` | Reads an OCI **index**; picks the entry with annotation `disktype=wsl`, `os=linux`, matching arch; that manifest must have **exactly one layer** with an `org.opencontainers.image.title` annotation. Default ref: `quay.io/podman/machine-os:<major.minor>` |
| `http(s)://…` | `stdpull.NewDiskFromURL` | Download, then decompress |
| local path | `stdpull.NewStdDiskPull` | `compression.Decompress` by magic number (zstd, xz, gzip, zip, or uncompressed) |

The result is a plain rootfs tar, passed to `wsl --import <dist> <dir> <tar> --version 2`.
So `podman-wsl-golden-<ver>.tar.zst` (zstd-compressed rootfs tar) is accepted as a local
file, from an http URL, or wrapped as an OCI artifact (`build/publish.sh --oci`).

Distro name: `podman-<machine name>` unless the name already starts with `podman`
(`env.WithPodmanPrefix`), so the default machine is the distro `podman-machine-default`.

## `podman machine init` (WSLStubber.CreateVM)

All commands run from Windows as `wsl -u root -d <dist> …` (Windows → Linux; not affected
by `[interop]`).

1. `wsl --import` (above).
2. `rpm --restore shadow-utils` (restores file capabilities of `newuidmap`/`newgidmap`).
3. `mkdir -p /usr/local/bin; ln -fs /usr/libexec/podman/gvforwarder /usr/local/bin/vm`.
4. If `--user-mode-networking`: imports **the same image** again as a second distro
   `podman-net-usermode` (see conflicts).
5. `configureSystem`:
   - appends `Port <ssh port>` to `/etc/ssh/sshd_config`
   - systemd links: enables `sshd.service`, system and user `podman.socket`; removes
     getty, `systemd-resolved`; masks `console-getty`, `systemd-oomd.socket`
   - `echo CREATE_MAIL_SPOOL=no >> /etc/default/useradd`
   - **`adduser -m user -G wheel`** (UID 1000, the `mc.SSH.RemoteUsername`)
   - **appends `%wheel ALL=(ALL) NOPASSWD: ALL` to `/etc/sudoers`**
   - `/etc/systemd/system/systemd-sysusers.service.d/override.conf` (`LoadCredential=`)
   - linger: `touch /var/lib/systemd/linger/user`
   - **overwrites `/etc/containers/containers.conf`** with `cgroup_manager = "cgroupfs"`
     and `[network] firewall_driver="iptables"`
   - **overwrites `/etc/containers/registries.conf.d/999-podman-machine.conf`** with
     `unqualified-search-registries=["docker.io"]`
   - `/etc/tmpfiles.d/podman-docker.conf`: `/run/docker.sock` → rootless (or rootful) Podman socket
   - **`echo wsl > /etc/containers/podman-machine`** (the marker; `containers/common`
     `machine.HostType()` reads it, and Podman then converts Windows paths
     `C:\x` → `/mnt/c/x` server side, `pkg/specgen/winpath.go`)
   - bind-mount units `podman-mnt-bindings.service` (system + user) exposing the sockets
     under `/mnt/wsl/podman-sockets/<dist>/`
   - **appends to `/etc/fstab`**:
     `/run/user/1000/podman/podman.sock /mnt/wsl/podman-sockets/<dist>/podman-user.sock none noauto,user,bind,defaults 0 0`
   - `/etc/systemd/system/podman.socket.d/10-group.conf`: `SocketMode=0660`, **`SocketGroup=wheel`**
   - `changeDistUserModeNetworking` → `writeWslConf`: **overwrites `/etc/wsl.conf`** with
     `[user]\ndefault=user`; with user-mode networking it then appends
     `[network] generateResolvConf = false` and writes `/etc/resolv.conf`
6. `installScripts`: `/usr/local/bin/enterns`, `/etc/profile.d/enterns.sh`, `/etc/wslmotd`,
   `/root/bootstrap`.
7. `createKeys`: appends the machine public key to `/root/.ssh/authorized_keys` and
   `/home/user/.ssh/authorized_keys`.
8. `wsl --terminate <dist>`.

Podman does **not** write `[boot]`, `[automount]` or `[interop]` in `wsl.conf`, and does
not mount anything (`MountVolumesToVM` is a no-op on WSL): it relies on WSL's automount
of `C:` at `/mnt/c`.

## `podman machine start` (StartVM + shim)

1. `wsl -u root -d <dist> /root/bootstrap`: if no `systemd` process exists, starts
   `unshare --kill-child --fork --pid --mount --mount-proc --propagation shared /lib/systemd/systemd`
   — **systemd runs in a nested PID namespace, not as PID 1**.
2. Readiness loop (`conductVMReadinessCheck`): state must be *Running*, which is
   `isSystemdRunning`: `ps -eo cmd,pid | grep -m 1 ^/lib/systemd/systemd` must return a PID;
   then the SSH port must listen and `ssh user@localhost true` must succeed.
3. `win-sshproxy.exe` (Windows side) forwards `\\.\pipe\docker_engine` and the Podman pipe
   to the API socket over SSH (as `user`, or `root` when rootful).
4. Optional: gvproxy for user-mode networking.

`podman machine stop`: `enterns systemctl exit 0` as root, waits for systemd, `wsl --terminate`.

Interactive `wsl -d <dist>` as `user`: `/etc/profile.d/enterns.sh` → `enterns` →
`sudo nsenter -m -p -t <systemd pid> … su -l user`. **This is the only runtime use of
sudo by `user`.** `podman machine ssh` lands directly in the systemd namespace via sshd
and needs no sudo.

## Consequences for the golden image

| Podman action | Effect on a baked-in setting | How the golden image handles it |
|---|---|---|
| overwrites `wsl.conf` | baked `[automount]`/`[interop]` lost | `harden.sh` merges required keys back in, keeps Podman's |
| overwrites `containers.conf` | baked settings lost | settings in `containers.conf.d/50-golden-image.conf` (survives); Podman's file kept |
| overwrites `999-podman-machine.conf` | `docker.io` becomes the unqualified registry, overriding `registries.conf` | `harden.sh` rewrites the drop-in |
| appends wheel NOPASSWD to sudoers | full root for `user` | `harden.sh` removes it, adds one argument-free rule |
| `SocketGroup=wheel` on rootful socket | wheel = root | `user` removed from wheel |
| appends fstab bind line | — | kept; `harden.sh` manages its own block only |
| writes `enterns` (needs broad sudo) | — | replaced by a version that needs only the helper |

Re-running `podman machine init` (new machine) repeats all of the above, so
`Invoke-Harden.ps1` always runs `harden.sh` after init.
