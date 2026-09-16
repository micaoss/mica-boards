#!/usr/bin/env bash
# The fetch-time mirror hook, against a local server that serves mica-res's
# contract: common/scripts/fetch-archive.sh for a `source` row and
# common/scripts/fetch-source.sh --name for a `git` row. No network: the
# mirror, the vendor host and the upstream git repository are all local.
#
# What every case is really checking: the fallback is the normal path and the
# mirror is an optimisation that may be absent, slow or wrong, and none of
# those may produce a wrong build -- or a hang.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH_ARCHIVE="${REPO_ROOT}/common/scripts/fetch-archive.sh"
FETCH_SOURCE="${REPO_ROOT}/common/scripts/fetch-source.sh"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

mkdir -p "${REPO_ROOT}/tmp"
T="$(mktemp -d "${REPO_ROOT}/tmp/mirror-hook-test.XXXXXX")"
SERVER_PID=""
cleanup() {
    [ -z "${SERVER_PID}" ] || kill "${SERVER_PID}" 2>/dev/null || true
    rm -rf "${T}"
}
trap cleanup EXIT

# The lock's own bytes, to prove at the end that no fetch rewrote a URL.
LOCK_BEFORE="$(sha256sum "${REPO_ROOT}/locks/upstream.lock" | cut -d' ' -f1)"

# ---- the mirror and the vendor host, one server, two trees -----------------
SITE="${T}/site"
mkdir -p "${SITE}/blob" "${SITE}/d/upstream/git" "${SITE}/vendor"
head -c 4096 /dev/urandom >"${T}/archive.bin"
ARCHIVE_SHA="$(sha256sum "${T}/archive.bin" | cut -d' ' -f1)"
cp "${T}/archive.bin" "${SITE}/vendor/toolchain.tar.xz"
mkdir -p "${SITE}/blob/${ARCHIVE_SHA:0:2}"
cp "${T}/archive.bin" "${SITE}/blob/${ARCHIVE_SHA:0:2}/${ARCHIVE_SHA}"

# An object only the vendor host has, for the 404 fallback.
head -c 4096 /dev/urandom >"${T}/only-vendor.bin"
ONLY_VENDOR_SHA="$(sha256sum "${T}/only-vendor.bin" | cut -d' ' -f1)"
cp "${T}/only-vendor.bin" "${SITE}/vendor/only-vendor.tar.xz"

# A wrong-bytes object, at a second sha256 the mirror answers for.
head -c 4096 /dev/urandom >"${T}/other.bin"
WRONG_SHA="$(sha256sum "${T}/other.bin" | cut -d' ' -f1)"
mkdir -p "${SITE}/blob/${WRONG_SHA:0:2}"
head -c 4096 /dev/urandom >"${SITE}/blob/${WRONG_SHA:0:2}/${WRONG_SHA}"
cp "${T}/other.bin" "${SITE}/vendor/other.tar.xz"

# An upstream git repository, its pack, and the mirror's manifest for it.
UP="${T}/upstream.git"
git init -q "${T}/work"
git -C "${T}/work" config user.email t@example.com
git -C "${T}/work" config user.name t
echo one >"${T}/work/a"
git -C "${T}/work" add a
GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000" git -C "${T}/work" commit -qm one
echo two >"${T}/work/b"
git -C "${T}/work" add b
GIT_AUTHOR_DATE="@1700000001 +0000" GIT_COMMITTER_DATE="@1700000001 +0000" git -C "${T}/work" commit -qm two
COMMIT="$(git -C "${T}/work" rev-parse HEAD)"
git clone -q --bare "${T}/work" "${UP}"
printf '%s\n' "${COMMIT}" | git -C "${UP}" pack-objects --revs --stdout >"${T}/pack"
PACK_SHA="$(sha256sum "${T}/pack" | cut -d' ' -f1)"
PACK_SIZE="$(stat -c%s "${T}/pack")"
NAME=test-kernel
PREFIX="${SITE}/d/upstream/git/${NAME}"
mkdir -p "${PREFIX}"
split -n 2 -d -a 2 "${T}/pack" "${PREFIX}/${COMMIT}.pack."
C0="${PREFIX}/${COMMIT}.pack.00"
C1="${PREFIX}/${COMMIT}.pack.01"
manifest() { # <file> <chunk0 sha> <chunk1 sha>
    cat >"$1" <<JSON
{ "schema": "mica/git-pack/v1", "repository": "mica-res", "name": "${NAME}",
  "url": "file://${UP}", "commit": "${COMMIT}",
  "pack": { "sha256": "${PACK_SHA}", "size": ${PACK_SIZE} },
  "chunks": [ { "sha256": "$2", "size": $(stat -c%s "${C0}") },
              { "sha256": "$3", "size": $(stat -c%s "${C1}") } ] }
JSON
}
manifest "${PREFIX}/${COMMIT}.json" "$(sha256sum "${C0}" | cut -d' ' -f1)" "$(sha256sum "${C1}" | cut -d' ' -f1)"

( cd "${SITE}" && exec python3 -u -m http.server 0 --bind 127.0.0.1 >"${T}/server.log" 2>&1 ) &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
    PORT="$(sed -n 's/.*127\.0\.0\.1 port \([0-9]*\).*/\1/p' "${T}/server.log" | sed -n 1p)"
    [ -z "${PORT}" ] || break
    sleep 0.2
done
[ -n "${PORT}" ] || { echo "the test server did not start: $(cat "${T}/server.log")" >&2; exit 1; }
MIRROR="http://127.0.0.1:${PORT}"
VENDOR="${MIRROR}/vendor"
DEAD="http://192.0.2.1"   # TEST-NET-1: routed nowhere, so this is the timeout case
REFUSED="http://127.0.0.1:1"

expect() { # <0|1> <case> <needle> <command>...
    local want="$1" name="$2" needle="$3" rc=0 out
    shift 3
    out="$("$@" 2>&1)" || rc=$?
    if { [ "${want}" = 0 ] && [ "${rc}" = 0 ]; } || { [ "${want}" = 1 ] && [ "${rc}" != 0 ]; }; then
        if [ -z "${needle}" ] || [ "${out#*"${needle}"}" != "${out}" ]; then pass "${name}"; return; fi
    fi
    fail "${name}: wanted exit ${want} with \"${needle}\", got ${rc}: ${out}"
}

# ---- the archives ----------------------------------------------------------

# The fallback first, because it is the path every network has: no mirror at all.
expect 0 "archive: no MICA_MIRROR fetches the row's URL" "not mirrored" \
    env -u MICA_MIRROR bash "${FETCH_ARCHIVE}" "${ARCHIVE_SHA}" "${VENDOR}/toolchain.tar.xz" "${T}/out.bin"
cmp -s "${T}/out.bin" "${T}/archive.bin" && pass "archive: the row's URL delivered the pinned bytes" \
    || fail "archive: the row's URL delivered other bytes"

expect 0 "archive: a mirror hit is used" "from the mirror" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_ARCHIVE}" "${ARCHIVE_SHA}" "http://127.0.0.1:1/never" "${T}/hit.bin"
cmp -s "${T}/hit.bin" "${T}/archive.bin" && pass "archive: the mirror delivered the pinned bytes" \
    || fail "archive: the mirror delivered other bytes"

expect 0 "archive: a mirror 404 falls back to the row's URL" "not mirrored" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_ARCHIVE}" \
    "${ONLY_VENDOR_SHA}" "${VENDOR}/only-vendor.tar.xz" "${T}/miss.bin"
cmp -s "${T}/miss.bin" "${T}/only-vendor.bin" && pass "archive: the fallback delivered the pinned bytes" \
    || fail "archive: the fallback delivered other bytes"

expect 1 "archive: wrong bytes from the mirror are refused, not fetched again" "not a trust anchor" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_ARCHIVE}" "${WRONG_SHA}" "${VENDOR}/other.tar.xz" "${T}/wrong.bin"
[ ! -e "${T}/wrong.bin" ] && pass "archive: the refused mirror bytes were removed" \
    || fail "archive: the refused mirror bytes were left behind"

expect 1 "archive: wrong bytes from the row's URL are refused" "locks/upstream.lock pins" \
    env -u MICA_MIRROR bash "${FETCH_ARCHIVE}" "${WRONG_SHA}" "${VENDOR}/toolchain.tar.xz" "${T}/bad.bin"

expect 0 "archive: a refused connection falls back" "not mirrored" \
    env MICA_MIRROR="${REFUSED}" bash "${FETCH_ARCHIVE}" "${ARCHIVE_SHA}" "${VENDOR}/toolchain.tar.xz" "${T}/refused.bin"

# The caveat this hook was designed around: a mirror that does not answer must
# cost a bounded wait, not a build that hangs once per object.
start="$(date +%s)"
MICA_MIRROR="${DEAD}" MICA_MIRROR_CONNECT_TIMEOUT=2 \
    bash "${FETCH_ARCHIVE}" "${ARCHIVE_SHA}" "${VENDOR}/toolchain.tar.xz" "${T}/timeout.bin" >/dev/null 2>&1
elapsed="$(($(date +%s) - start))"
[ "${elapsed}" -le 6 ] && pass "archive: an unreachable mirror costs ${elapsed}s and falls back" \
    || fail "archive: an unreachable mirror cost ${elapsed}s"

# ---- the git trees ---------------------------------------------------------

expect 0 "git: no MICA_MIRROR clones upstream" "" \
    env -u MICA_MIRROR bash "${FETCH_SOURCE}" --name "${NAME}" "${T}/g-plain" "file://${UP}" "${COMMIT}"
[ "$(git -C "${T}/g-plain" rev-parse HEAD 2>/dev/null)" = "${COMMIT}" ] \
    && pass "git: the clone is at the pinned commit" || fail "git: the clone is not at the pinned commit"

expect 0 "git: a mirrored pack is imported" "imported from the mirror, 2 chunk(s)" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_SOURCE}" --name "${NAME}" "${T}/g-mirror" "file://${T}/does-not-exist" "${COMMIT}"
[ "$(git -C "${T}/g-mirror" rev-parse HEAD 2>/dev/null)" = "${COMMIT}" ] \
    && pass "git: the imported tree is at the pinned commit" || fail "git: the imported tree is not at the pinned commit"
[ "$(cat "${T}/g-mirror/.git/shallow" 2>/dev/null)" = "${COMMIT}" ] \
    && pass "git: .git/shallow names the pinned commit" || fail "git: .git/shallow is not the pinned commit"
cmp -s "${T}/g-mirror/a" "${T}/work/a" && cmp -s "${T}/g-mirror/b" "${T}/work/b" \
    && pass "git: the working tree is the upstream tree" || fail "git: the working tree differs from upstream"
git -C "${T}/g-mirror" fsck --no-progress >/dev/null 2>&1 \
    && pass "git: the imported repository is fsck clean" || fail "git: the imported repository is not fsck clean"

expect 0 "git: an unmirrored row clones upstream" "is not mirrored" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_SOURCE}" --name absent-kernel "${T}/g-404" "file://${UP}" "${COMMIT}"
[ "$(git -C "${T}/g-404" rev-parse HEAD 2>/dev/null)" = "${COMMIT}" ] \
    && pass "git: the fallback clone is at the pinned commit" || fail "git: the fallback clone is not at the pinned commit"

expect 0 "git: without --name the mirror is not consulted" "" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_SOURCE}" "${T}/g-noname" "file://${UP}" "${COMMIT}"

# A truncated or wrong chunk is an error rather than something handed to git.
manifest "${PREFIX}/${COMMIT}.json" "$(printf 'b%.0s' {1..64})" "$(sha256sum "${C1}" | cut -d' ' -f1)"
expect 1 "git: a wrong chunk sha256 is refused" "is refused here rather than handed to git" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_SOURCE}" --name "${NAME}" "${T}/g-chunk" "file://${UP}" "${COMMIT}"

# A manifest for another commit is not this tree's pack.
sed "s/\"commit\": \"${COMMIT}\"/\"commit\": \"$(printf 'c%.0s' {1..40})\"/" \
    "${PREFIX}/${COMMIT}.json" >"${T}/other.json"
manifest "${PREFIX}/${COMMIT}.json" "$(sha256sum "${C0}" | cut -d' ' -f1)" "$(sha256sum "${C1}" | cut -d' ' -f1)"
cp "${T}/other.json" "${PREFIX}/${COMMIT}.json"
expect 1 "git: a manifest for another commit is refused" "was refused" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_SOURCE}" --name "${NAME}" "${T}/g-commit" "file://${UP}" "${COMMIT}"

# A manifest that is not the schema is refused rather than guessed at.
printf '{ "schema": "something/else", "commit": "%s" }\n' "${COMMIT}" >"${PREFIX}/${COMMIT}.json"
expect 1 "git: a manifest of another schema is refused" "was refused" \
    env MICA_MIRROR="${MIRROR}" bash "${FETCH_SOURCE}" --name "${NAME}" "${T}/g-schema" "file://${UP}" "${COMMIT}"

# ---- the rule that does not bend ------------------------------------------
[ "$(sha256sum "${REPO_ROOT}/locks/upstream.lock" | cut -d' ' -f1)" = "${LOCK_BEFORE}" ] \
    && pass "no fetch rewrote a lock URL" || fail "locks/upstream.lock changed during the fetches"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = 0 ]
