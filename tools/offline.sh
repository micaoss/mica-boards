#!/usr/bin/env bash
# The whole build of this checkout, locally: what CI builds, from the clean
# commit and the inputs it pins, with nothing published.
#
#   make offline                    (docker; on an x64 host the arm64 pool is emulated)
#
#   reads   meta/verity/signer.cert.pem, meta/boot/signer.cert.pem   (or VERITY_TRUST_CERT, FIT_TRUST_CERT:
#                                                                      the public certificates, which must be
#                                                                      the ones trust-certificates.sha256 records)
#   writes  _out/<board>/                     every board's kernel and firmware (make kernels firmware)
#           _out/debs/<amd64|arm64>/          both pools: pool/, Packages, SHA256SUMS, manifest.txt (make pool),
#                                             gated per architecture and across both (make package-gate)
#           _out/boards/<board>/<component>/  each board's components (tools/component.sh: board, kernel,
#                                             uboot, firmware), each with its inputs hash in inputs.sha256
#
# The boards are boards/boards.tsv's, and each one's outputs must be what its
# outputs.tsv lists: the archives of its pool and exactly each component's files.
#
# A dirty tree is refused: every archive carries the commit it was built from.
# _out/debs and _out/boards are replaced, so they hold only this commit's build.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
cd "${REPO_ROOT}"
die() { echo "offline.sh: error: $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the tree has uncommitted changes; commit them, then build"
bash tools/boards.sh check
commit="$(git rev-parse HEAD)"

VERITY="$(realpath "${VERITY_TRUST_CERT:-meta/verity/signer.cert.pem}")" || die "no verity certificate at ${VERITY_TRUST_CERT:-meta/verity/signer.cert.pem}"
FIT="$(realpath "${FIT_TRUST_CERT:-meta/boot/signer.cert.pem}")" || die "no FIT boot certificate at ${FIT_TRUST_CERT:-meta/boot/signer.cert.pem}"
for pair in "meta/verity/signer.cert.pem:${VERITY}" "meta/boot/signer.cert.pem:${FIT}"; do
    want="$(sed -n "s|^\([0-9a-f]\{64\}\)  ${pair%%:*}\$|\1|p" trust-certificates.sha256)"
    [ -n "${want}" ] || die "trust-certificates.sha256 records no ${pair%%:*}"
    [ "$(sha256sum "${pair#*:}" | cut -d' ' -f1)" = "${want}" ] || die "${pair#*:} is not the certificate trust-certificates.sha256 records for ${pair%%:*}"
done

rm -rf _out/debs _out/boards
make kernels firmware VERITY_TRUST_CERT="${VERITY}" FIT_TRUST_CERT="${FIT}"
VERITY_TRUST_CERT="${VERITY}" make pool
make package-gate GATE_ARGS="--arch amd64"
make package-gate GATE_ARGS="--arch arm64"
make package-gate GATE_ARGS=--static

for board in $(bash tools/boards.sh list); do
    arch="$(bash tools/boards.sh arch "${board}")"
    bash tools/boards.sh pool-has "${board}" "_out/debs/${arch}/pool"
    for component in $(bash tools/component.sh list "${board}"); do
        VERITY_TRUST_CERT="${VERITY}" bash tools/component.sh stage "${board}" "${component}" "_out/boards/${board}/${component}"
        VERITY_TRUST_CERT="${VERITY}" FIT_TRUST_CERT="${FIT}" bash tools/inputs.sh "${board}" "${component}" >"_out/boards/${board}/${component}.inputs.sha256"
    done
done

echo "offline.sh: built ${commit}"
echo "offline.sh: kernels and firmware  ${REPO_ROOT}/_out/<board>/"
for a in amd64 arm64; do
    echo "offline.sh: ${a} pool  ${REPO_ROOT}/_out/debs/${a}/ ($(grep -c . "_out/debs/${a}/SHA256SUMS") archives)"
done
for board in $(bash tools/boards.sh list); do
    echo "offline.sh: ${board} ($(bash tools/boards.sh arch "${board}"))  pool ${REPO_ROOT}/_out/debs/$(bash tools/boards.sh arch "${board}")/ ($(bash tools/boards.sh packages "${board}" | wc -l) archives listed), components ${REPO_ROOT}/_out/boards/${board}/{$(bash tools/component.sh list "${board}" | paste -sd, -)}/"
done
