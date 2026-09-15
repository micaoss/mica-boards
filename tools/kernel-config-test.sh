#!/usr/bin/env bash
# The shared kernel floor over every board's committed configuration, the
# boards discovered: a UEFI board's config is kernel/config/<board>.config and
# its post-olddefconfig gate its kernel/Dockerfile; a FIT board (one with a
# bsp.env) names its config there (KERNEL_CONFIG) and its gate is its
# kernel/configure.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
n=0
for env in boards/*/board.env; do
    board="$(basename "$(dirname "${env}")")"
    if [ ! -f "boards/${board}/bsp.env" ]; then
        config="boards/${board}/kernel/config/${board}.config"; gate="boards/${board}/kernel/Dockerfile"
    else
        name="$(sed -n 's/^KERNEL_CONFIG=//p' "boards/${board}/bsp.env" | head -1)"
        [ -n "${name}" ] || { echo "error: boards/${board}/bsp.env declares no KERNEL_CONFIG" >&2; exit 1; }
        config="boards/${board}/kernel/config/${name}"; gate="boards/${board}/kernel/configure.sh"
    fi
    bash common/kernel/kernel-config-test.sh "${board}" "${config}" "${gate}"
    n=$((n + 1))
done
[ "${n}" -gt 0 ] || { echo "error: no board.env found; the loop above checked nothing" >&2; exit 1; }
echo "kernel-config-test: ${n} board(s)"
