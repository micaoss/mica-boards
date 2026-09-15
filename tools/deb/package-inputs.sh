#!/usr/bin/env bash
# The inputs hash of a producer at one architecture: sha256 over a sorted
# manifest of everything that determines its archives' bytes, apart from the
# identity every build stamps (version, source commit, SOURCE_DATE_EPOCH). A
# board release reuses a published archive whose pool layer carries this hash as
# mica.inputs (tools/deb/reuse.sh), and records it on every layer it publishes.
#
#   bash tools/deb/package-inputs.sh <producer> <amd64|arm64|all>             the hash
#   bash tools/deb/package-inputs.sh --manifest <producer> <amd64|arm64|all>  the manifest it is taken over
#
# The manifest, as `<kind> <name> <value>` lines:
#   file      producer.env, the FOR_EACH instance file, the producer directory's tracked files, tools/deb/,
#             VERSION, and each BUILD_CONTEXTS entry: the paths its Dockerfile COPYs from that context, or
#             the whole context when the producer has a PREPARE hook (which may read anything in it)
#   hook      for a PREPARE hook that runs `make -C <dir> <target>`, that directory's tracked files, common/,
#             and locks/upstream.lock
#   pin       the build-env image rows it packs in (base, and FROM_IMAGES)
#   arch      the architecture it is built at
# Deliberately wide: a missed input would reuse a stale archive, an extra one only rebuilds.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
die() { echo "package-inputs.sh: error: $*" >&2; exit 1; }

MODE=hash
[ "${1-}" != --manifest ] || { MODE=manifest; shift; }
[ "$#" -eq 2 ] || die "usage: bash tools/deb/package-inputs.sh [--manifest] <producer> <amd64|arm64|all>"
PRODUCER="$1" ARCH="$2"
case "${ARCH}" in amd64 | arm64 | all) ;; *) die "'${ARCH}' is not amd64, arm64 or all" ;; esac
cd "${REPO_ROOT}"
DIR="$(bash tools/deb/producers.sh --dir-for "${PRODUCER}")" || die "no producer ${PRODUCER}"
INSTANCE="$(bash tools/deb/producers.sh --instance-for "${PRODUCER}")"
vals="$(
    BUILD_CONTEXTS="" FROM_IMAGES="" PREPARE=""
    # shellcheck disable=SC1090
    [ -z "${INSTANCE}" ] || . "./${INSTANCE}"
    # shellcheck disable=SC1090
    . "./${DIR}/producer.env"
    printf 'C=%s\nF=%s\nP=%s\n' "${BUILD_CONTEXTS}" "${FROM_IMAGES}" "${PREPARE}"
)"
CONTEXTS="$(sed -n 's/^C=//p' <<<"${vals}")"
FROM_IMAGES="$(sed -n 's/^F=//p' <<<"${vals}")"
PREPARE="$(sed -n 's/^P=//p' <<<"${vals}")"

files() { # <path>...: tracked files and their sha256
    git ls-files -z -- "$@" | while IFS= read -r -d '' f; do
        if [ -L "${f}" ]; then printf 'link %s %s\n' "${f}" "$(readlink "${f}")"; else printf 'file %s %s\n' "${f}" "$(sha256sum "${f}" | cut -d' ' -f1)"; fi
    done
}
# The sources a Dockerfile COPYs from the named context <name>: `COPY --from=<name> <src>... <dest>`.
copied_from() { # <dockerfile> <name>
    awk -v n="$2" '
        { line = line $0; if (sub(/\\$/, "", line)) next }
        { split(line, w, /[ \t]+/); line = "" }
        toupper(w[1]) == "COPY" {
            from = ""; first = 0
            for (i = 2; i <= length(w); i++) { if (w[i] ~ /^--from=/) { from = substr(w[i], 8) } else if (w[i] !~ /^--/) { first = i; break } }
            if (from == n && first) for (i = first; i < length(w); i++) print w[i]
        }' "$1"
}

{
    printf 'producer %s\n' "${PRODUCER#*@}"
    printf 'arch %s\n' "${ARCH}"
    files "${DIR}" tools/deb VERSION
    [ -z "${INSTANCE}" ] || files "${INSTANCE}"
    for entry in ${CONTEXTS}; do
        name="${entry%%=*}" path="${entry#*=}"
        case "${name}" in packer | bin) continue ;; esac
        if [ -n "${PREPARE}" ]; then
            files "${path}"
        else
            mapfile -t srcs < <(copied_from "${DIR}/Dockerfile" "${name}")
            if [ "${#srcs[@]}" -eq 0 ]; then files "${path}"; else files "${srcs[@]/#/${path}/}"; fi
        fi
    done
    if [ -n "${PREPARE}" ]; then
        # A hook that builds with `make -C <dir>` reads that directory, common/ and the upstream pins.
        sed -n 's|.*make -C "\$MICA_DEB_REPO_ROOT/\([^"]*\)".*|\1|p' "${DIR}/${PREPARE}" | sort -u | while IFS= read -r d; do
            files "${d}" common | sed 's/^file /hook /'
            printf 'hook locks/upstream.lock %s\n' "$(sha256sum locks/upstream.lock | cut -d' ' -f1)"
        done
    fi
    printf 'pin mica-build-env:base %s\n' "$(bash tools/from.sh --ref base)"
    for entry in ${FROM_IMAGES}; do printf 'pin %s %s\n' "${entry#*=}" "$(bash tools/from.sh "X=${entry#*=}" | tail -n1)"; done
} | sort -u >"${TMPDIR:-/tmp}/package-inputs.$$"
trap 'rm -f "${TMPDIR:-/tmp}/package-inputs.$$"' EXIT
if [ "${MODE}" = manifest ]; then cat "${TMPDIR:-/tmp}/package-inputs.$$"; else sha256sum <"${TMPDIR:-/tmp}/package-inputs.$$" | cut -d' ' -f1; fi
