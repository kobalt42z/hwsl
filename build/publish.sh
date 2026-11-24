#!/bin/bash
# -----------------------------------------------------------------------------
# publish.sh - publish a built golden image to Artifactory.
#
#   build/publish.sh out/podman-wsl-golden-<ver>.tar.zst [--generic URL] [--oci REF]
#
# --generic URL  upload to a generic repo, e.g.
#                https://artifactory.example.com/artifactory/wsl-images/podman-wsl-golden/
#                Clients then use: podman machine init --image <URL>/<file>
#                (or download it first; SCCM usually ships the file itself).
# --oci REF      push as a machine-os style OCI artifact index, e.g.
#                docker://artifactory.example.com/wsl-images-local/podman-machine-golden:5.8
#                Clients then use: podman machine init --image docker://...
#                Needs podman >= 5 on the build agent.
#
# Auth: ARTIFACTORY_USER / ARTIFACTORY_TOKEN.
# -----------------------------------------------------------------------------
set -euo pipefail
file="${1:?tar.zst}"; shift
generic=""; oci=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --generic) generic="${2:?}"; shift 2 ;;
        --oci)     oci="${2:?}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ -n "$generic$oci" ]] || { echo "need --generic and/or --oci" >&2; exit 1; }
[[ -f "$file" ]] || { echo "no such file: $file" >&2; exit 1; }
sha="$(sha256sum "$file" | cut -d' ' -f1)"
base="$(basename "$file")"

if [[ -n "$generic" ]]; then
    : "${ARTIFACTORY_USER:?}" "${ARTIFACTORY_TOKEN:?}"
    for f in "$file" "${file}.sha256" "${file%.tar.zst}.json"; do
        [[ -f "$f" ]] || continue
        curl -fsS -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
             -H "X-Checksum-Sha256: $(sha256sum "$f" | cut -d' ' -f1)" \
             -T "$f" "${generic%/}/$(basename "$f")" >/dev/null
        echo "uploaded ${generic%/}/$(basename "$f")"
    done
fi

if [[ -n "$oci" ]]; then
    # Same shape Podman expects from quay.io/podman/machine-os
    # (pkg/machine/ocipull/source.go): an index whose entry has
    # annotation disktype=wsl, os=linux, arch=x86_64 (or aarch64), and exactly
    # one layer titled with the original file name.
    arch="${ARCH:-x86_64}"
    list="localhost/golden-machine-os-index:tmp-$$"
    podman manifest rm "$list" >/dev/null 2>&1 || true
    podman manifest create "$list" >/dev/null
    podman manifest add --artifact --artifact-type application/vnd.oci.image.layer.v1.tar+zstd \
        --os linux --arch "$arch" --annotation disktype=wsl "$list" "$file" >/dev/null
    podman manifest push --all \
        ${ARTIFACTORY_USER:+--creds "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}"} "$list" "$oci"
    podman manifest rm "$list" >/dev/null
    echo "pushed $oci (disktype=wsl, $arch, layer $base sha256:$sha)"
fi
