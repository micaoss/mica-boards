#!/usr/bin/env bash
# The Ubuntu archive snapshot the kernel and U-Boot builders install from, as
# the value of their MICA_APT_SNAPSHOT build argument, read from the
# ubuntu-<suite> source rows of locks/upstream.lock:
#
#   bash tools/apt-snapshot.sh
#   -> 20260915T000000Z noble=<sha256> noble-security=<sha256> noble-updates=<sha256>
#
# Every row names one snapshot instant and the sha256 of that suite's signed
# InRelease; common/scripts/apt-install.sh points apt at the snapshot and refuses
# an InRelease with another hash, so every package it installs is the one that
# InRelease names. A snapshot moves by replacing all the rows together.
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${MICA_LOCKS_DIR:-${REPO_ROOT}/locks}/upstream.lock"
die() { echo "apt-snapshot.sh: error: $*" >&2; exit 1; }
[ "$#" -eq 0 ] || die "usage: bash tools/apt-snapshot.sh"
rows="$(awk -F'\t' '$1 == "source" && $2 ~ /^ubuntu-/' "${LOCK}")"
[ -n "${rows}" ] || die "${LOCK} pins no ubuntu-<suite> snapshot rows"
instant="$(cut -f4 <<<"${rows}" | sort -u)"
[ "$(grep -c . <<<"${instant}")" = 1 ] && [[ "${instant}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "the ubuntu-<suite> rows of ${LOCK} do not name one snapshot instant: $(tr '\n' ' ' <<<"${instant}")"
value="${instant}"
while IFS=$'\t' read -r _kind name arch version sha url; do
    suite="${name#ubuntu-}"
    [ "${arch}" = all ] && [ "${url}" = "https://snapshot.ubuntu.com/ubuntu/${version}/dists/${suite}/InRelease" ] ||
        die "the row ${name} is not the all-architecture InRelease of suite ${suite} at ${version}: ${arch} ${url}"
    value="${value} ${suite}=${sha}"
done <<<"${rows}"
printf '%s\n' "${value}"
