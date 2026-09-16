#!/usr/bin/env bash
# The fetch-time mirror. mica-res keeps a copy of every third-party object this
# repository pins, addressed by content, and this library is the only place
# that knows its URL shape. Sourced by fetch-archive.sh and fetch-source.sh;
# it is not a program.
#
#   MICA_MIRROR=https://res.micaos.dev   the base. Unset or empty: no hook at all.
#
# Three rules this file exists to keep.
#
# A LOCK URL IS NEVER REWRITTEN. The pinned URL is an input of the component
# (tools/inputs.sh reads locks/upstream.lock), so rewriting one would move the
# inputs hash and rebuild and republish the component. The mirror is consulted
# at fetch time, in the builder, and nowhere else.
#
# THE MIRROR IS A SOURCE, NEVER A TRUST ANCHOR. What proves an object is the
# right one is the sha256 of the lock row, or -- for a git pack -- git's own
# object hashing plus the rev-parse assertion in fetch-source.sh. Bytes that do
# not match are a refusal, never a reason to fall back: falling back would turn
# a corrupted mirror into a silent slow path nobody notices.
#
# NOT REACHABLE IS NOT AN ERROR. 404, a connection timeout, a DNS failure and a
# TLS failure all mean "not mirrored", and the pinned URL is used instead. The
# mirror answers from CI and does not answer from every network, so no build may
# wait on it: the connect timeout is three seconds and there is no retry.

MICA_MIRROR_CONNECT_TIMEOUT="${MICA_MIRROR_CONNECT_TIMEOUT:-3}"

mirror_base() { # the base without its trailing slash, empty when the hook is off
    local base="${MICA_MIRROR:-}"
    printf '%s' "${base%/}"
}

mirror_get() { # <path> <dest>: 0 and the bytes are in <dest>, 1 and it is not mirrored
    local path="$1" dest="$2" base
    base="$(mirror_base)"
    [ -n "${base}" ] || return 1
    # --speed-limit/--speed-time rather than --max-time: the largest mirrored
    # object is 345 MiB, so a deadline would refuse a slow network while a
    # stalled transfer is what must be given up on.
    if curl -fsSL --connect-timeout "${MICA_MIRROR_CONNECT_TIMEOUT}" \
        --speed-limit 1024 --speed-time 20 --retry 0 \
        -o "${dest}" "${base}/${path}" 2>/dev/null; then
        return 0
    fi
    rm -f "${dest}"
    return 1
}

mirror_sha256() { # <file>
    sha256sum "$1" | cut -d' ' -f1
}
