#!/usr/bin/env bash
# Reuse the unchanged archives of a board's previous release in this release's
# pool, instead of re-versioning them. Runs after `make pool POOL_BOARD=<board>`
# and before the package gate, on the pool's own architecture.
#
#   bash tools/deb/reuse.sh --board <board> --arch <amd64|arm64> --release <board>/<YYYYMMDD-HHMM>
#
#   reads   the board's latest published release other than --release: its mica-boards.lock and its
#           pool manifest, whose layers carry each archive's mica.inputs (all read anonymously)
#   writes  in _out/debs/<arch>/: the published archives of every producer whose inputs
#           (tools/deb/package-inputs.sh) equal its layers', in place of this build's; reused.tsv, one row
#           per reused archive (package, version, architecture, sha256, repository, commit, inputs), which
#           the package gate holds like lock rows and the publisher accepts; previous-pool.json, the
#           previous pool manifest, when every producer is reused (the publisher re-tags it when its
#           layers are exactly this pool's); the pool index (tools/deb/repo.sh)
#
# The inputs decide reuse, and a published archive is taken only once it is
# proven to be what this tree builds: downloaded at its layer digest, equal to
# the previous lock's package row, and equal byte for byte to a rebuild of its
# producer here as that archive's identity (Version, Mica-Source-Commit,
# SOURCE_DATE_EPOCH; tools/deb/build.sh MICA_DEB_IDENTITY) on an empty-cache
# builder. A missing or corrupt archive, or a rebuild that differs, stops the
# release; nothing is silently rebuilt instead. A producer with a changed input
# keeps this build's archives.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
# shellcheck disable=SC1091
. "${HERE}/registry.sh"
die() { echo "reuse.sh: error: $*" >&2; exit 1; }
usage="usage: bash tools/deb/reuse.sh --board <board> --arch <amd64|arm64> --release <board>/<YYYYMMDD-HHMM>"

BOARD="" ARCH="" RELEASE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --board) BOARD="${2-}"; shift 2 ;;
    --arch) ARCH="${2-}"; shift 2 ;;
    --release) RELEASE="${2-}"; shift 2 ;;
    *) die "${usage}" ;;
    esac
done
[ -n "${BOARD}" ] && [ "${RELEASE%%/*}" = "${BOARD}" ] || die "${usage}"
case "${ARCH}" in amd64 | arm64) ;; *) die "${usage}" ;; esac
[ "$(bash "${REPO_ROOT}/tools/boards.sh" arch "${BOARD}")" = "${ARCH}" ] || die "${BOARD} is not built for ${ARCH}"
cd "${REPO_ROOT}"
POOL="_out/debs/${ARCH}/pool"
[ -d "${POOL}" ] || die "${POOL} does not exist; run make pool POOL_BOARD=${BOARD} POOL_ARCH=${ARCH} first"
REUSED="_out/debs/${ARCH}/reused.tsv"
PREVIOUS_POOL="_out/debs/${ARCH}/previous-pool.json"
: >"${REUSED}"
rm -f "${PREVIOUS_POOL}"

registry_load
registry_repo_name
ARTIFACT="$(oci_repo "${REPO_NAME}")"
SLUG="${MICA_SOURCE_URL#https://github.com/}/${REPO_NAME}"
# Overridable so a test can serve releases from file://.
LIST_URL="${MICA_RELEASE_LIST:-https://api.github.com/repos/${SLUG}/releases?per_page=100}"
DOWNLOAD="${MICA_RELEASE_DOWNLOAD:-https://github.com/${SLUG}/releases/download}"
WORK="$(mktemp -d)"
BUILDER="mica-deb-reuse-$$"
trap 'docker buildx rm "${BUILDER}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

curl -fsSL "${LIST_URL}" -o "${WORK}/releases.json" || die "listing the releases of ${SLUG} failed"
previous="$(jq -r --arg b "${BOARD}/" --arg skip "${RELEASE}" '[.[] | select(.draft == false and (.tag_name | startswith($b)) and .tag_name != $skip
    and ([.assets[].name] | index("mica-boards.lock")))] | map(.tag_name) | sort | last // empty' "${WORK}/releases.json")"
[ -n "${previous}" ] || { echo "reuse.sh: ${BOARD} has no previous release; every archive is this build's"; bash tools/deb/repo.sh --arch "${ARCH}"; exit 0; }
curl -fsSL "${DOWNLOAD}/${previous}/mica-boards.lock" -o "${WORK}/lock" || die "downloading mica-boards.lock of ${previous} failed"
reference="$(awk -F'\t' -v a="${ARCH}" '$1 == "pool" && $2 == a { print $3 }' "${WORK}/lock")"
[ -n "${reference}" ] || die "mica-boards.lock of ${previous} has no ${ARCH} pool row"
status="$(REGISTRY_TOKEN='' oci_manifest_get "${ARTIFACT}" "${reference##*@}" "${WORK}/pool.json")"
[ "${status}" = 200 ] && [ "$(oci_manifest_digest "${WORK}/pool.json")" = "${reference##*@}" ] ||
    die "the pool ${reference} of ${previous} does not read anonymously at its digest (HTTP ${status})"
# title, digest and inputs of every published archive
jq -r '.layers[] | [.annotations["org.opencontainers.image.title"], .digest, (.annotations["mica.inputs"] // "-")] | @tsv' "${WORK}/pool.json" >"${WORK}/layers.tsv"

reused=0 kept=0
while read -r producer _dir arches packages _enablement; do
    case ",${arches}," in *",all,"*) build_arch=all ;; *",${ARCH},"*) build_arch="${ARCH}" ;; *) continue ;; esac
    inputs="$(bash tools/deb/package-inputs.sh "${producer}" "${build_arch}")"
    titles=()
    for p in ${packages//,/ }; do
        title="$(awk -F'\t' -v p="${p}_" -v s="_${build_arch}.deb" -v i="${inputs}" \
            'index($1, p) == 1 && substr($1, length($1) - length(s) + 1) == s && $3 == i { print $1 }' "${WORK}/layers.tsv")"
        [ -n "${title}" ] || { titles=(); break; }
        titles+=("${title}")
    done
    if [ "${#titles[@]}" -eq 0 ]; then
        kept=$((kept + 1))
        echo "reuse.sh: ${producer}: inputs ${inputs:0:12} differ from ${previous}'s; this build's archives stay"
        continue
    fi

    # The published archives, at their digests and their lock rows, and the one identity they carry.
    identity=""
    for title in "${titles[@]}"; do
        digest="$(awk -F'\t' -v t="${title}" '$1 == t { print $2 }' "${WORK}/layers.tsv")"
        status="$(REGISTRY_TOKEN='' oci_blob_get "${ARTIFACT}" "${digest}" "${WORK}/${title}")"
        [ "${status}" = 200 ] || die "${title} of ${previous} does not download anonymously at ${digest} (HTTP ${status})"
        sha="$(sha256sum "${WORK}/${title}" | cut -d' ' -f1)"
        [ "sha256:${sha}" = "${digest}" ] || die "${title} of ${previous} downloads as sha256:${sha}, not its layer digest ${digest}"
        awk -F'\t' -v n="${title%%_*}" -v a="${ARCH}" -v s="${sha}" '$1 == "package" && $2 == n && $3 == a && $5 == s { f = 1 } END { exit !f }' "${WORK}/lock" ||
            die "${title} of ${previous} (sha256 ${sha}) is not a package row of its lock"
        mapfile -t fields < <(python3 tools/deb/control-fields.py "${WORK}/${title}" Version Mica-Source-Repo Mica-Source-Commit)
        epoch="$(python3 - "${WORK}/${title}" <<'PY'
import importlib.util, io, sys, tarfile
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('fields', 'tools/deb/control-fields.py')
fields = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fields)
for name, body in fields.members(sys.argv[1]):
    if name.startswith('data.tar'):
        with tarfile.open(fileobj=io.BytesIO(body), mode='r:*') as t:
            mtimes = {m.mtime for m in t.getmembers()}
        # pack.sh sets every member's mtime to SOURCE_DATE_EPOCH
        print(mtimes.pop() if len(mtimes) == 1 else '')
PY
)"
        this="${fields[0]:-} ${fields[2]:-} ${epoch}"
        [ "${fields[1]:-}" = "${REPO_NAME}" ] && [ -n "${epoch}" ] || die "${title} of ${previous} is not an archive of ${REPO_NAME} with one member mtime"
        [ -z "${identity}" ] || [ "${identity}" = "${this}" ] || die "the published archives of ${producer} carry different identities (${identity} / ${this})"
        identity="${this}"
    done
    read -r version commit epoch <<<"${identity}"

    # A rebuild here as that identity, on a fresh builder so no packing layer is replayed.
    echo "reuse.sh: ${producer}: inputs ${inputs:0:12} are ${previous}'s; rebuilding it as ${version} to prove the published archives"
    docker buildx create --name "${BUILDER}-${reused}" --driver docker-container >/dev/null
    log="${WORK}/${producer}.log"
    MICA_DEB_IDENTITY="${identity}" MICA_POOL_DIR="${WORK}/rebuild" BUILDX_BUILDER="${BUILDER}-${reused}" BUILDKIT_PROGRESS=plain \
        bash tools/deb/build.sh --producer "${producer}" --arch "${build_arch}" >"${log}" 2>&1 ||
        { tail -n 20 "${log}" >&2; docker buildx rm "${BUILDER}-${reused}" >/dev/null 2>&1 || true; die "rebuilding ${producer} as ${version} failed"; }
    docker buildx rm "${BUILDER}-${reused}" >/dev/null 2>&1 || true
    for title in "${titles[@]}"; do
        [ "$(grep -c "pack\.sh: ${title} " "${log}" || true)" -gt 0 ] || die "the rebuild of ${producer} carries no 'pack.sh: ${title}' line; its packing layer was not run"
        cmp -s "${WORK}/rebuild/${ARCH}/pool/${title}" "${WORK}/${title}" ||
            die "${producer} rebuilt as ${version} is not the published ${title}: its unchanged inputs do not reproduce it"
    done
    for p in ${packages//,/ }; do rm -f "${POOL}/${p}"_*.deb; done
    for title in "${titles[@]}"; do
        cp "${WORK}/${title}" "${POOL}/${title}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${title%%_*}" "${version}" "${build_arch}" "$(sha256sum "${POOL}/${title}" | cut -d' ' -f1)" "${REPO_NAME}" "${commit}" "${inputs}" >>"${REUSED}"
    done
    reused=$((reused + 1))
done < <(bash tools/boards.sh producers "${BOARD}")

[ "${kept}" -gt 0 ] || cp "${WORK}/pool.json" "${PREVIOUS_POOL}"
bash tools/deb/repo.sh --arch "${ARCH}"
echo "reuse.sh: ${BOARD} ${ARCH}: ${reused} producer(s) reused from ${previous}, ${kept} built here"
