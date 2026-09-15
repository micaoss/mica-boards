#!/usr/bin/env bash
# mica-build-side: container -- this runs inside the BSP builder image, where apt
# is the image's own package manager; there is no apt step on the host.
#
# Install the build dependencies a BSP component names from the pinned Ubuntu
# archive snapshot, and leave no apt lists behind.
#
#   MICA_APT_SNAPSHOT='<instant> <suite>=<InRelease sha256>...' apt-install.sh git ca-certificates build-essential ...
#
# MICA_APT_SNAPSHOT is tools/apt-snapshot.sh's value, read from the ubuntu-<suite>
# rows of locks/upstream.lock and handed in as a build argument. apt is pointed at
# https://snapshot.ubuntu.com/ubuntu/<instant>/ for exactly those suites, and every
# InRelease it fetched must have its pinned sha256; the archive signature then
# ties every index and package to it, so the toolchain a component is built with
# cannot move while the rows stay. The image carries no CA bundle, so TLS peer
# verification is off for that one host: authenticity is the archive keyring's
# signature and the pinned InRelease hashes, as for any apt mirror.
#
# The package LIST stays in the Dockerfile that needs it: it is the one part of
# this step that differs between the kernel and U-Boot builders, and a reader
# asking "what toolchain built this artefact" should find the answer in the file
# that declares the base image rather than one directory away. What is shared is
# the step -- the snapshot, update, --no-install-recommends, and the cleanup that
# keeps the lists out of the layer.
set -euo pipefail

[ "$#" -gt 0 ] || {
    echo "error: apt-install.sh was called with no packages. A call with none would run apt-get update, install nothing and exit 0, which reads exactly like a dependency list that arrived" >&2
    exit 1
}
read -r instant pins <<<"${MICA_APT_SNAPSHOT:-}"
[[ "${instant:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && [ -n "${pins:-}" ] || {
    echo "error: MICA_APT_SNAPSHOT='${MICA_APT_SNAPSHOT:-}' is not '<instant> <suite>=<sha256>...'; the board's Makefile passes tools/apt-snapshot.sh's value, and without it apt would install whatever the live archive holds today" >&2
    exit 1
}

suites=""
for pin in ${pins}; do suites="${suites} ${pin%%=*}"; done
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat >/etc/apt/sources.list.d/mica-snapshot.sources <<SOURCES
Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/${instant}/
Suites:${suites}
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
echo 'Acquire::https::snapshot.ubuntu.com::Verify-Peer "false";' >/etc/apt/apt.conf.d/50mica-snapshot

apt-get -o APT::Update::Error-Mode=any update
for pin in ${pins}; do
    suite="${pin%%=*}"
    file="/var/lib/apt/lists/snapshot.ubuntu.com_ubuntu_${instant}_dists_${suite}_InRelease"
    [ -f "${file}" ] || { echo "error: apt fetched no InRelease for ${suite} at ${instant}" >&2; exit 1; }
    got="$(sha256sum "${file}" | cut -d' ' -f1)"
    [ "${got}" = "${pin#*=}" ] || { echo "error: the ${suite} InRelease of snapshot ${instant} has sha256 ${got}, and locks/upstream.lock pins ${pin#*=}" >&2; exit 1; }
done
apt-get install -y --no-install-recommends "$@"
rm -rf /var/lib/apt/lists/*
