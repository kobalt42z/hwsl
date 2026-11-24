# hwsl: hardened Podman WSL golden image

A hardened golden image of the **Podman machine WSL distro** for developer PCs that run
Visual Studio 2026 Docker Compose projects on Podman (WSL provider).

The design rule: harden the distro **without breaking Podman's own provisioning or VS
debugging**. Every change below was checked against what Podman 5.8.9 does inside the
distro. That analysis is in [docs/podman-provisioning.md](docs/podman-provisioning.md).
Where a requirement conflicts with Podman, it is listed under
[Conflicts with Podman provisioning](#conflicts-with-podman-provisioning), with options.

> **Status: not yet validated on Windows.** The build and `harden.sh` pass an offline Linux
> test that replays Podman's provisioning (`tests/linux/`). Everything that needs a real
> Windows + WSL + VS 2026 machine is listed in [Manual acceptance steps](#manual-acceptance-steps).

## Layout

| Path | What it is |
|---|---|
| `config/golden-image.env` | All settings and placeholders. It is baked into the image as `/etc/golden-image/config.env` |
| `build/build.sh` | Reproducible build: fetch the base, import it, apply `Containerfile`, export to `out/podman-wsl-golden-<ver>.tar.zst` |
| `build/fetch-base.sh` | Downloads the official machine OS WSL rootfs (`disktype=wsl`) from quay.io or an Artifactory proxy and verifies its digest |
| `build/Containerfile`, `build/files/image-prepare.sh` | Image layer: CA, dnf mirror, package removal, image-wide config |
| `build/publish.sh` | Uploads to an Artifactory generic repo, or pushes a machine-os style OCI artifact |
| `post-init/harden.sh` | Runs as root after `podman machine init`. Idempotent. Baked in at `/usr/local/libexec/golden-image/harden.sh` |
| `post-init/lib/enterns*` | Replacement for Podman's `enterns`, and the single sudo-allowed helper |
| `post-init/Invoke-Harden.ps1` | Windows/SCCM wrapper: init, then harden, then restart, then verify, then store a reference manifest |
| `compliance/Test-WslCompliance.ps1` | Windows compliance check. Outputs JSON and an exit code |
| `tests/acceptance.ps1` | Acceptance criteria on a Windows dev PC |
| `tests/linux/` | Offline Linux tests (simulated `podman machine init` + `harden.sh`), also run in CI |

## Configuration (placeholders)

Edit `config/golden-image.env`, or keep a site file and pass `--config site.env`.
Environment variables override both.

| Placeholder | Variable | Default / note |
|---|---|---|
| `<PODMAN_VERSION>` | `PODMAN_VERSION` | `5.8.9`, the latest 5.x. The base is `machine-os:5.8` |
| `<ARTIFACTORY_HOST>` | `ARTIFACTORY_HOST` + `ARTIFACTORY_REPO_*` | `artifactory.example.com`, remote repos `dockerhub-remote`, `quay-remote`, `ghcr-remote`, `mcr-remote` |
| `<CA_FILE>` | `CA_FILE` | **required**, PEM |
| `<DNF_MIRROR>` | `DNF_MIRROR` (+ `DNF_REPO_*_PATH`) | Fedora layout `…/releases/$releasever/Everything/$basearch/os/` |
| `<Edition>` | `VS_EDITION` | `Enterprise`. `Invoke-Harden.ps1` detects the real path with `vswhere` and passes `--vs-root` |
| base image | `BASE_IMAGE_REF` | `docker://quay.io/podman/machine-os:5.8`. Point it at your Artifactory quay proxy for offline builds |

Other switches: `REGISTRY_MODE` (`redirect`|`block`), `DEFAULT_CAPABILITIES`,
`REMOVE_PACKAGES`, `WSL_BOOT_SYSTEMD`, `RESTRICT_SUDO`, `REMOVE_USER_FROM_WHEEL`,
`VS_RO_SUBPATHS`, `NUGET_FALLBACK_PATH`.

## What the image changes

| Requirement | Where | Implementation |
|---|---|---|
| 1 users/privilege | `harden.sh` | `user` (UID 1000) kept. Podman's `%wheel NOPASSWD: ALL` is removed and `user` is removed from `wheel`. The only sudo rule is `user ALL=(root) NOPASSWD: /usr/local/libexec/golden-image/enterns-user ""` (no arguments). `enterns` is replaced so that non-root callers can only get a login shell |
| 2 `wsl.conf` | image + `harden.sh` | INI merge: `[automount] enabled=false, mountFsTab=true`, `[interop] enabled=false, appendWindowsPath=false`, `[user] default=user`, `[boot] systemd=false` (see conflicts). Keys Podman writes (e.g. `[network]`) are kept |
| 3 mounts | `harden.sh` | Managed block in `/etc/fstab`. drvfs, `C:/…` device, `\040` escaping, `uid=1000,gid=1000`, `metadata` on rw mounts, `nosuid,nodev,nofail`. Mount points are `/mnt/c/...`, exactly as Podman translates `C:\...` (drive letter lower-cased, case kept). Other drvfs/9p lines are removed. Podman's socket bind line is kept |
| 4 registries | `harden.sh` | `registries.conf`: `unqualified-search-registries=["<ARTIFACTORY_HOST>"]`, `short-name-mode="enforcing"`, `[[registry]]` redirect (or block) for docker.io, quay.io, ghcr.io, mcr.microsoft.com. `registry-1.docker.io` is blocked. Podman's `999-podman-machine.conf` (which sets docker.io) is rewritten |
| 4 containers.conf | `harden.sh` | `containers.conf.d/50-golden-image.conf`: reduced `default_capabilities` (drops SETFCAP, SETPCAP, SYS_CHROOT), `log_driver` and `events_logger` set to `journald`. Podman's own `containers.conf` is left intact. Rootless stays the default |
| 5 CA | image | `/etc/pki/ca-trust/source/anchors/<CA_NAME>.crt` + `update-ca-trust` |
| 6 packages | image | Public repos removed. `golden-mirror.repo` points at `DNF_MIRROR`. `REMOVE_PACKAGES` are removed offline with a protected list, and the build fails if any command Podman needs is gone |
| 7 tamper evidence | `harden.sh` | `/etc/golden-image/manifest.sha256` (SHA-256 of wsl.conf, fstab, registries.conf(.d), containers.conf(.d), sudoers(.d), CA anchor and bundle, the Podman marker, enterns, the harden scripts, sshd drop-in, dnf repos, version, config) and `/etc/golden-image/version` |
| extra | `harden.sh` | `sshd_config.d/50-golden-image.conf`: keys only, root by key only (Podman needs root keys for rootful mode) |

## Build

On a Linux build agent (rootful, so file ownership in the tar is exact). Needs podman
(or docker), curl, jq, zstd, python3.

```bash
sudo CA_FILE=certs/corp-root.pem \
     BASE_IMAGE_REF=docker://artifactory.example.com/quay-remote/podman/machine-os:5.8 \
     REGISTRY_USER=svc-build REGISTRY_PASSWORD=*** \
     build/build.sh --config site.env
# -> out/podman-wsl-golden-5.8.9-1.tar.zst (+ .sha256, .json with base digest and git commit)
```

Offline or with a pre-downloaded base: `build/build.sh --base-tar <machine-os wsl rootfs .tar.zst>`.
The image build itself runs with `--network=none`.

Bump `GOLDEN_VERSION` for every release. The output tar is reproducible in content but
not byte-for-byte, because of timestamps. Use the `.json` record (base digest, commit) for
traceability.

## Publish to Artifactory

```bash
export ARTIFACTORY_USER=svc-build ARTIFACTORY_TOKEN=***
# generic repo (what SCCM packages usually pull from)
build/publish.sh out/podman-wsl-golden-5.8.9-1.tar.zst \
  --generic https://artifactory.example.com/artifactory/wsl-images/podman-wsl-golden/
# optional: OCI artifact in the machine-os format, usable as --image docker://...
build/publish.sh out/podman-wsl-golden-5.8.9-1.tar.zst \
  --oci docker://artifactory.example.com/wsl-images-local/podman-machine-golden:5.8
```

Podman without `--image` pulls `quay.io/podman/machine-os`, which there is no internet to
reach. Either always pass `--image`, or set the default in the Windows
`%APPDATA%\containers\containers.conf` under `[machine] image = "docker://…"`.

## Install (SCCM)

Deploy in the **logged-on user's context**. Podman machines and WSL distros are per user,
and the script refuses to run as SYSTEM.

```powershell
powershell.exe -ExecutionPolicy Bypass -File post-init\Invoke-Harden.ps1 `
  -ImagePath "\\sccm\pkg\podman-wsl-golden-5.8.9-1.tar.zst" `
  -ExpectedSha256 <sha from .sha256>
```

The script:
1. checks that the Podman client matches the image (`-ExpectedPodmanVersion 5.8`)
2. runs `podman machine init --image …` (`-Force` replaces an existing machine; this deletes its containers)
3. creates the approved Windows folders if they don't exist, and finds VS 2026 with `vswhere`
4. runs `wsl -d podman-machine-default -u root --exec …/harden.sh --win-user … --profile … --appdata … --vs-root …` (`--exec` means no shell, so backslashes and spaces arrive verbatim)
5. terminates the distro and runs `podman machine start`
6. runs `harden.sh --verify`, then copies the manifest to `%LOCALAPPDATA%\GoldenImage\<distro>\manifest.sha256` and writes `install.json`

Exit codes: 0 OK, 1 failure, 2 precondition not met. There is a log next to the reference manifest.

## Upgrade

- **New golden image** (new CA, new base, config change): bump `GOLDEN_VERSION`, build,
  publish, and redeploy with `-Force`. A WSL machine can't be upgraded in place. Containers
  and images in the old machine are lost, so tell developers to push anything they need.
- **Podman for Windows minor upgrade** (e.g. 5.8.x → 5.8.y): the existing distro is not
  re-provisioned, so the manifest stays valid. Run the compliance script afterwards.
  For a new minor *series* (5.9), re-read `pkg/machine/wsl` for that tag
  (see [docs/podman-provisioning.md](docs/podman-provisioning.md)), rebuild on
  `machine-os:5.9`, and redeploy.
- After any sanctioned in-distro change (`podman machine set --rootful`,
  `dnf update ca-certificates`), re-run `harden.sh` as root, which regenerates the
  manifest, and refresh the reference copy by re-running `Invoke-Harden.ps1` without `-Force`.

## Compliance

```powershell
compliance\Test-WslCompliance.ps1 -ExpectedGoldenVersion 5.8.9-1 -OutFile C:\ProgramData\GoldenImage\compliance.json
```

The script checks the following: only approved distros are registered in Lxss (HKCU, or
all loaded user hives with `-AllUsers`, which runs only the registry checks when run as
SYSTEM); all distros are WSL 2; the `wsl --version` minimum; the Podman client version; the
golden version; live file hashes against the in-distro manifest; the in-distro manifest
against the reference copy outside the distro; and no new files in watched dirs (for
example an extra `sudoers.d` file). The output is JSON, with exit code 0 for PASS, 1 for
FAIL and 2 for error.

## Credentials (Artifactory)

- **VS 2026 / docker CLI** talk to Podman's Docker-compatible API through the
  `docker_engine` pipe, and send registry credentials per request (`X-Registry-Auth`). The
  credentials stay on Windows, in `%USERPROFILE%\.docker\config.json` with
  `"credsStore": "wincred"` (Windows Credential Manager). Nothing is written into the distro.
- **`podman login` from Windows** stores credentials in the Windows user's Podman auth file
  on the client (check the `--authfile` default in `podman login --help` for your version).
  It sits under the user profile, so the profile ACL protects it. Pass `--authfile` to pin
  the location.
- **Inside the distro** (rootless, user `user`): `podman login` writes
  `${XDG_RUNTIME_DIR}/containers/auth.json` = `/run/user/1000/containers/auth.json`
  (tmpfs, 0600, gone after a restart). For a persistent login, use
  `~/.config/containers/auth.json` via `REGISTRY_AUTH_FILE`, owned by `user` with mode 0600.
  Rootful: `/run/containers/0/auth.json`.
- Never bake credentials into the image. Prefer anonymous read on the Artifactory *remote*
  repos for the internal network, or per-developer identity tokens.

## Conflicts with Podman provisioning

These come from reading the Podman 5.8.9 source. For each one, the shipped default is
marked, and so are the parts not yet confirmed on Windows.

1. **`[boot] systemd=true` breaks `podman machine start`.** Podman starts its own systemd
   in a nested PID namespace (`/root/bootstrap`), and decides that the machine is running
   with `ps -eo cmd,pid | grep -m 1 ^/lib/systemd/systemd`. Under WSL's native systemd,
   PID 1 is `/sbin/init`, and units run as `/usr/lib/systemd/...`. Detection then finds no
   PID, so the readiness loop ends with *"machine did not transition into running state"*.
   `enterns` and `podman machine stop` (`enterns systemctl exit 0`) also become no-ops.
   - **A (default): `WSL_BOOT_SYSTEMD=false`.** systemd still runs, started by Podman, so
     journald, the socket units and linger all work. Only the WSL-native boot path is
     unused.
   - B: `WSL_BOOT_SYSTEMD=true`. You get the requirement as written, and `machine start`
     is expected to fail. Try it on one PC to confirm.
   - C: change the detection. It lives in `podman.exe` (`isSystemdRunning`), and the
     constraint is not to modify Podman binaries.
2. **`interop=false` and `automount=false` are fine for the machine distro, but break
   user-mode networking.** The machine distro itself doesn't need either: all of Podman's
   calls are Windows→Linux `wsl.exe -u root` invocations. But `--user-mode-networking`
   imports *the same image* as a second distro, `podman-net-usermode`, which starts
   `gvproxy.exe` through interop from `/mnt/c/...`. That distro would also get the baked
   `wsl.conf`.
   - **A (default): user-mode networking is not supported.** The compliance check fails if
     `podman-net-usermode` is registered, unless you pass `-AllowUserModeNetworkingDistro`.
   - B: for VPN users who need it, build a second flavour without the baked interop and
     automount settings for the helper distro, and accept the larger surface there.
3. **Mounts outside the approved list fail by design.** Podman translates `C:\x` to
   `/mnt/c/x`, and doesn't mount anything itself. A Compose file binding a folder outside
   the list fails at container create with "no such file or directory". Repos outside
   `%USERPROFILE%\source\repos` need `harden.sh --extra-mount 'D:\repos:rw'` (which shows
   up in the manifest).
4. **Sudo.** Podman's runtime needs root for one thing as `user`: the login path
   (`/etc/profile.d/enterns.sh` → `sudo nsenter … su -l user`). `podman machine ssh`, the
   API and compose don't use sudo. Every other root action Podman takes uses
   `wsl -u root` from Windows. So the sudoers rule is exactly one argument-free helper.
   `RESTRICT_SUDO=false` restores Podman's rule.
5. **wheel = root.** Podman sets the rootful socket to `SocketGroup=wheel`, mode 0660, so
   any wheel member can drive rootful Podman. That's why `user` is removed from `wheel`.
   Rootful mode (`podman machine set --rootful`) keeps working, because the Windows side
   connects as root over SSH with Podman's key.
6. **Registries: block versus redirect.** VS Dockerfiles use fully qualified
   `mcr.microsoft.com/dotnet/...` images, and the short-name aliases in containers-common
   map `alpine` to `docker.io/library/alpine`. Blocking those prefixes breaks VS and makes
   `podman pull alpine` fail.
   - **A (default): `REGISTRY_MODE=redirect`.** Names stay the same and the bytes come from
     Artifactory. `registry-1.docker.io` is blocked. The acceptance check for "direct
     docker.io pull fails" then tests that docker.io can't be reached directly
     (registry-1/egress), because `docker.io/...` names resolve to Artifactory.
   - B: `REGISTRY_MODE=block`. The public prefixes are `blocked=true` and the alias file is
     emptied. Every reference must name Artifactory, including VS Dockerfiles.
7. **`containers.conf` is overwritten by init.** The golden settings go in a drop-in
   instead, so Podman's `cgroup_manager=cgroupfs` and `firewall_driver=iptables` (both
   needed on WSL) survive. Both files are in the manifest.

## Known limitations

- **The developer is not the adversary.** `wsl -d … -u root` always works. The hardening
  limits malicious code running as `user`, and makes tampering detectable. A root process
  can rewrite both the files and the in-distro manifest. The reference copy in
  `%LOCALAPPDATA%` is writable by the Windows user too. For stronger evidence, collect the
  compliance JSON centrally (SCCM/Intune) and compare manifest hashes across the fleet per
  `GOLDEN_VERSION`. Only `fstab` depends on the user.
- **Registry policy is config, not enforcement.** Rootless Podman also reads
  `~/.config/containers/registries.conf`, so code running as `user` can override it. The
  real control is network egress: allow only Artifactory and the mirror from the PC.
- **WSL mounts some Windows paths itself**: `/usr/lib/wsl/drivers` and `/usr/lib/wsl/lib`
  (GPU, read-only), and `/mnt/wslg` (WSLg). These are not controlled by `fstab`. Evaluate
  `guiApplications=false` in `.wslconfig` and the `[gpu]` section of `wsl.conf` for your
  WSL version. `.wslconfig` is per Windows user and is not part of this image.
- **Reduced capabilities apply to `podman build` too.** A Dockerfile that runs `setcap`
  (for example packages installed with file capabilities) or uses `chroot` needs
  `--cap-add SETFCAP`/`SYS_CHROOT`, or a wider `DEFAULT_CAPABILITIES`.
- **The CA bundle hash changes** when `ca-certificates` is updated inside the distro. The
  manifest then needs a refresh (re-run `harden.sh`).
- `podman machine set --rootful` / `--user-mode-networking` / an SSH port change rewrite
  files that Podman owns. Expect a compliance FAIL until `harden.sh` is re-run.
- `harden.sh` expects the Podman 5.8 file layout. Re-check it for other minor series.
- The PowerShell scripts target Windows PowerShell 5.1 and PowerShell 7. CI runs
  PSScriptAnalyzer on them, but they haven't been executed on Windows yet.

## Manual acceptance steps

These can't be checked without a real Windows + WSL + VS 2026 PC. `tests/acceptance.ps1`
automates the rest.

1. **Find the exact VS 2026 mounts** (requirement 3). Start a Compose debug session (F5) on
   a stock Podman machine, then run
   `podman inspect <container> --format '{{json .Mounts}}'`. Compare the `Source` paths
   under `C:\Program Files\Microsoft Visual Studio\18\<Edition>\…` and the NuGet fallback
   folder with `VS_RO_SUBPATHS` / `NUGET_FALLBACK_PATH`, and adjust them. The defaults
   (`MSBuild\Sdks\Microsoft.Docker.Sdk\tools`, `Common7\IDE\CommonExtensions\Microsoft\HotReload`,
   `C:\Program Files (x86)\Microsoft Visual Studio\Shared\NuGetPackages`) are based on
   VS 2022 behaviour.
2. **drvfs syntax.** Confirm on WSL that `C:/Program\040Files/...` mounts at boot
   (`findmnt -t 9p`), and that `wsl --shutdown` followed by start leaves only the approved
   mounts.
3. **VS 2026**: Compose up, F5 with a breakpoint hit, Hot Reload applying an edit. File
   watching over drvfs doesn't get inotify events from Windows editors, so check that VS
   sets `DOTNET_USE_POLLING_FILE_WATCHER` in its generated compose override.
4. **Podman minor upgrade**: upgrade Podman for Windows, then run
   `tests\acceptance.ps1 -SkipInstall`. AC5 must still PASS.
5. **Conflict 1, option B** (only if you want to confirm it): set `WSL_BOOT_SYSTEMD=true`
   on a test build and check that `podman machine start` fails as described.

## Tests

```bash
# Linux, offline: stand-in base, simulated podman init, harden.sh assertions
sudo tests/linux/make-test-base.sh /tmp/base.tar.zst podman
sudo CA_FILE=/tmp/ca.pem build/build.sh --base-tar /tmp/base.tar.zst --out /tmp/out
sudo tests/linux/test-harden.sh /tmp/out/podman-wsl-golden-*.tar.zst podman
```

```powershell
# Windows dev PC (removes and recreates the test machine)
tests\acceptance.ps1 -ImagePath .\podman-wsl-golden-5.8.9-1.tar.zst -ArtifactoryHost artifactory.example.com
```
