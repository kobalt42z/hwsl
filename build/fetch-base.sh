#!/bin/bash
# -----------------------------------------------------------------------------
# fetch-base.sh - download the official Podman machine OS WSL rootfs.
#
# The machine OS is published as an OCI index (quay.io/podman/machine-os:<X.Y>)
# whose entries carry an annotation "disktype" (wsl, hyperv, applehv, qemu).
# Podman 5.8.9 selects the entry with disktype=wsl + os=linux + arch, and that
# entry has exactly one layer: the compressed rootfs tar
# (pkg/machine/ocipull/source.go, GetDiskArtifactReference). We do the same
# with plain registry v2 calls so it works against an Artifactory remote repo
# that proxies quay.io, with no Podman/skopeo needed on the build host.
#
# Usage: fetch-base.sh <docker://host/repo:tag> <arch> <out-dir>
# Auth (optional): REGISTRY_USER / REGISTRY_PASSWORD (Artifactory API key).
# Prints the path of the downloaded file on stdout.
# -----------------------------------------------------------------------------
set -euo pipefail

ref="${1:?docker://host/repo:tag}"; arch="${2:?arch}"; out="${3:?out dir}"
ref="${ref#docker://}"
host="${ref%%/*}"; rest="${ref#*/}"
repo="${rest%:*}"; tag="${rest##*:}"
[[ "$repo" != "$rest" ]] || { echo "reference needs a tag: $1" >&2; exit 1; }
api="https://${host}/v2/${repo}"

log() { printf '[fetch-base] %s\n' "$*" >&2; }
mkdir -p "$out"

auth_args=()
token=""
if [[ -n "${REGISTRY_USER:-}" ]]; then
    auth_args=(-u "${REGISTRY_USER}:${REGISTRY_PASSWORD:?REGISTRY_PASSWORD}")
fi

# Bearer token dance (quay.io, Artifactory with token auth).
get_token() {
    local hdr realm service scope
    hdr="$(curl -sS -o /dev/null -D - "${auth_args[@]}" "${api}/tags/list" | tr -d '\r' \
           | awk 'tolower($1)=="www-authenticate:" {sub(/^[^ ]+ /,""); print}')"
    [[ "$hdr" == Bearer* ]] || return 0
    realm="$(sed -nE 's/.*realm="([^"]+)".*/\1/p' <<<"$hdr")"
    service="$(sed -nE 's/.*service="([^"]+)".*/\1/p' <<<"$hdr")"
    scope="repository:${repo}:pull"
    token="$(curl -fsS "${auth_args[@]}" -G "$realm" \
             --data-urlencode "service=${service}" --data-urlencode "scope=${scope}" \
             | jq -r '.token // .access_token')"
}

reg_curl() {
    if [[ -n "$token" ]]; then
        curl -fsSL -H "Authorization: Bearer ${token}" "$@"
    else
        curl -fsSL "${auth_args[@]}" "$@"
    fi
}

get_token

accept_index="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"
accept_manifest="application/vnd.oci.image.manifest.v1+json"

log "index ${host}/${repo}:${tag}"
index="$(reg_curl -H "Accept: ${accept_index}" "${api}/manifests/${tag}")"
digest="$(jq -r --arg a "$arch" '
    .manifests[]
    | select(.annotations.disktype == "wsl" and .platform.os == "linux" and .platform.architecture == $a)
    | .digest' <<<"$index" | head -n1)"
[[ -n "$digest" && "$digest" != null ]] || { log "no disktype=wsl entry for ${arch}"; exit 1; }
log "wsl artifact manifest ${digest}"

manifest="$(reg_curl -H "Accept: ${accept_manifest}" "${api}/manifests/${digest}")"
[[ "$(jq '.layers | length' <<<"$manifest")" == 1 ]] || { log "expected exactly one layer"; exit 1; }
blob="$(jq -r '.layers[0].digest' <<<"$manifest")"
name="$(jq -r '.layers[0].annotations["org.opencontainers.image.title"] // empty' <<<"$manifest")"
name="${name:-podman-machine-wsl-${arch}.tar.zst}"
name="$(basename -- "$name")"

dest="${out}/${name}"
if [[ -f "$dest" ]] && [[ "sha256:$(sha256sum "$dest" | cut -d' ' -f1)" == "$blob" ]]; then
    log "cached ${dest}"
else
    log "downloading ${blob} -> ${dest}"
    reg_curl -o "${dest}.part" "${api}/blobs/${blob}"
    [[ "sha256:$(sha256sum "${dest}.part" | cut -d' ' -f1)" == "$blob" ]] \
        || { log "digest mismatch"; rm -f "${dest}.part"; exit 1; }
    mv -f "${dest}.part" "$dest"
fi

jq -n --arg ref "$1" --arg index_digest "sha256:$(printf '%s' "$index" | sha256sum | cut -d' ' -f1)" \
      --arg manifest "$digest" --arg blob "$blob" --arg file "$name" \
      '{base_ref:$ref, index_digest:$index_digest, wsl_manifest:$manifest, rootfs_blob:$blob, file:$file}' \
      > "${out}/base-info.json"
printf '%s\n' "$dest"
