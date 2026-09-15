#!/usr/bin/env bash
# Package reuse by inputs, end to end on the x64 board's real producer against a
# real registry: tools/deb/reuse.sh takes an archive of the board's previous
# release when its producer's inputs are unchanged and a rebuild as that
# archive's identity is the same bytes, the package gate holds it like a lock
# row, and tools/deb/publish.sh publishes it as it is and re-tags the previous
# pool manifest. A changed input rebuilds; a missing archive, a lock row that
# does not name it and an archive the tree does not reproduce are refused.
#
#   bash tests/package-reuse-test.sh          (docker on the host)
#
# The scripts run in a scratch clone of the working tree, untracked files
# included, committed and tagged there (the tags never leave the clone). The
# registry is registry:3.1.1 from locks/mica-build-env.lock, a sibling container
# over plain HTTP; previous releases are served from file://.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
for t in curl sha256sum jq docker git python3; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required" >&2; exit 1; }
done
mkdir -p "${REPO_ROOT}/_out"
WORK="$(mktemp -d "${REPO_ROOT}/_out/package-reuse-test.XXXXXX")"
NAME="ai-agent-package-reuse-test-$$"
cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; rm -rf "${WORK}"; }
trap cleanup EXIT
PASS_N=0; FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $1"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $1"; }
says() { grep -c -- "$2" "$1" >/dev/null; }

IMAGE="$(bash tools/from.sh --upstream registry:3.1.1)"
docker run -d --rm --label ai-agent=true --name "${NAME}" --network "${MICA_TEST_NETWORK:-traefik}" -e REGISTRY_STORAGE_DELETE_ENABLED=true "${IMAGE}" >/dev/null
for _ in $(seq 1 30); do curl -sf -o /dev/null "http://${NAME}:5000/v2/" && break; sleep 1; done
curl -sf -o /dev/null "http://${NAME}:5000/v2/" || { echo "error: the registry ${NAME} did not answer" >&2; exit 1; }
REG="http://${NAME}:5000/v2/one/mica-boards"
MT='application/vnd.oci.image.manifest.v1+json'

CLONE="${WORK}/repo"
git clone -q "${REPO_ROOT}" "${CLONE}"
git -C "${CLONE}" remote set-url origin https://example.invalid/testorg/mica-boards.git
git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - | tar -xf - -C "${CLONE}"
commit() { # <message>: everything in the clone, tagged <tag> by the caller
    git -C "${CLONE}" add -A
    git -C "${CLONE}" -c user.name=test -c user.email=test@example.invalid commit -qm "$1" --allow-empty
}
commit "the working tree under test"
POOL="${CLONE}/_out/debs/amd64/pool"

RELEASES="${WORK}/releases"
mkdir -p "${RELEASES}/download"
echo '[]' >"${RELEASES}/releases.json"
remember() { # <tag> <lock>: a published release the next one may reuse from
    mkdir -p "${RELEASES}/download/$1"
    cp "$2" "${RELEASES}/download/$1/mica-boards.lock"
    jq --arg t "$1" '. + [{tag_name: $t, draft: false, assets: [{name: "mica-boards.lock"}, {name: "SHA256SUMS"}]}]' "${RELEASES}/releases.json" >"${RELEASES}/r.json"
    mv "${RELEASES}/r.json" "${RELEASES}/releases.json"
}
cat >"${WORK}/registry.env" <<ENV
MICA_REGISTRY=${NAME}:5000/one
MICA_REGISTRY_USER=nobody
MICA_RELEASE_TOKEN_VAR=PUBLISH_TEST_TOKEN
MICA_SOURCE_URL=https://example.invalid/testorg
ENV
run() { # <tag> <log> <command...>: in the clone, for the release <tag>
    local tag="$1" log="$2"; shift 2
    (cd "${CLONE}" && MICA_REGISTRY_ENV="${WORK}/registry.env" MICA_REGISTRY_PLAIN_HTTP=1 MICA_RELEASE_NO_GH=1 PUBLISH_TEST_TOKEN=fixture \
        MICA_RELEASE_TAG="${tag}" MICA_LOCK_ROWS="${WORK}/rows-${tag//\//-}" \
        MICA_RELEASE_LIST="file://${RELEASES}/releases.json" MICA_RELEASE_DOWNLOAD="file://${RELEASES}/download" \
        "$@") >"${log}" 2>&1
}
# release <tag>: pack the pool at HEAD, reuse, publish it; writes the pool and package rows of a lock.
release() {
    local tag="$1" base="${WORK}/${1//\//-}"
    git -C "${CLONE}" tag "${tag}"
    rm -rf "${CLONE}/_out/debs"
    run "${tag}" "${base}-pool.log" bash tools/deb/build.sh --producer board@x64 --arch amd64 &&
        run "${tag}" "${base}-reuse.log" bash tools/deb/reuse.sh --board x64 --arch amd64 --release "${tag}" &&
        run "${tag}" "${base}-publish.log" bash tools/deb/publish.sh || return 1
    {
        echo "# mica-lock v1"
        awk -F'\t' '{ printf "pool\t%s\tghcr.io/micaoss/mica-boards:%s@%s\n", $1, $2, $3 }' "${WORK}/rows-${tag//\//-}/pool.tsv"
        awk -F'\t' '{ printf "package\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }' "${WORK}/rows-${tag//\//-}/package.tsv"
    } >"${base}.lock"
}
served() { echo "sha256:$(curl -sf -H "Accept: ${MT}" "${REG}/manifests/$1" | sha256sum | cut -d' ' -f1)"; } # <tag>
deb_sha() { sha256sum "${POOL}"/mica-board-x64_*.deb | cut -d' ' -f1; }
inputs() { (cd "${CLONE}" && bash tools/deb/package-inputs.sh board@x64 amd64); }

# 1. The first release has nothing to reuse; its layer carries the inputs.
A=x64/20260101-0000
if release "${A}" && says "${WORK}/x64-20260101-0000-reuse.log" "has no previous release"; then pass "first release: built here, nothing reused"
else fail "first release: $(tail -n3 "${WORK}"/x64-20260101-0000-*.log)"; fi
A_SHA="$(deb_sha)"; A_POOL="$(served pool.x64.amd64.20260101-0000)"
[ -n "$(inputs)" ] && [ "$(curl -sf -H "Accept: ${MT}" "${REG}/manifests/pool.x64.amd64.20260101-0000" | jq -r '.layers[0].annotations["mica.inputs"]')" = "$(inputs)" ] &&
    pass "the pool layer carries the producer's inputs as mica.inputs" || fail "layer mica.inputs"
remember "${A}" "${WORK}/x64-20260101-0000.lock"

# 2. A later commit that changes no input of the producer: the published archive and pool are reused.
printf '\nA change outside every package input.\n' >>"${CLONE}/docs/changelog.md"
commit "outside the inputs"
B=x64/20260101-0100
if release "${B}" && says "${WORK}/x64-20260101-0100-reuse.log" "1 producer(s) reused from ${A}, 0 built here"; then pass "unchanged inputs: the archive is reused"
else fail "unchanged inputs: $(tail -n5 "${WORK}"/x64-20260101-0100-*.log)"; fi
[ "$(deb_sha)" = "${A_SHA}" ] && pass "the reused archive is the published bytes, at its version" || fail "the pool holds $(ls "${POOL}")"
[ "$(cut -f1,4,7 "${CLONE}/_out/debs/amd64/reused.tsv")" = "$(printf 'mica-board-x64\t%s\t%s' "${A_SHA}" "$(inputs)")" ] && pass "reused.tsv names it with its sha256 and inputs" || fail "reused.tsv: $(cat "${CLONE}/_out/debs/amd64/reused.tsv")"
if (cd "${CLONE}" && bash tools/deb/package-gate.sh --board x64 --arch amd64) >"${WORK}/gate.log" 2>&1 && says "${WORK}/gate.log" "imported, and is its lock row"; then pass "the package gate holds the reused archive to its row"
else fail "gate over a reused pool: $(grep -E 'FAIL|error' "${WORK}/gate.log" | head -n5)"; fi
[ "$(served pool.x64.amd64.20260101-0100)" = "${A_POOL}" ] && says "${WORK}/x64-20260101-0100-publish.log" "is put under" &&
    pass "every archive reused: the new pool tag names the previous pool's digest" || fail "pool digest $(served pool.x64.amd64.20260101-0100) against ${A_POOL}"
remember "${B}" "${WORK}/x64-20260101-0100.lock"

# 3. A changed input of the producer: rebuilt at this commit, a new pool.
printf '# a changed input\n' >>"${CLONE}/producers/board/producer.env"
commit "a producer input"
C=x64/20260101-0200
if release "${C}" && says "${WORK}/x64-20260101-0200-reuse.log" "0 producer(s) reused from ${B}, 1 built here"; then pass "changed inputs: the archive is rebuilt"
else fail "changed inputs: $(tail -n5 "${WORK}"/x64-20260101-0200-*.log)"; fi
case "$(ls "${POOL}")" in *"+git$(git -C "${CLONE}" rev-parse --short=12 HEAD)-1_"*) pass "the rebuilt archive carries this commit's version" ;; *) fail "rebuilt version: $(ls "${POOL}")" ;; esac
[ "$(served pool.x64.amd64.20260101-0200)" != "${A_POOL}" ] && pass "a rebuilt archive: a new pool digest" || fail "the pool was reused over a changed input"

# 4. Refusals, each against one crafted previous release at the current inputs.
refused() { # <previous lock> <expected message> <label>
    echo '[]' >"${RELEASES}/releases.json"
    rm -rf "${RELEASES}/download/x64/20260101-0250"
    remember x64/20260101-0250 "$1"
    rm -rf "${CLONE}/_out/debs"
    run x64/20260101-0300 "${WORK}/refuse.log" bash tools/deb/build.sh --producer board@x64 --arch amd64 || { fail "$3: the pool did not build"; return; }
    if run x64/20260101-0300 "${WORK}/refuse.log" bash tools/deb/reuse.sh --board x64 --arch amd64 --release x64/20260101-0300; then fail "$3: reused"
    elif says "${WORK}/refuse.log" "$2"; then pass "$3: refused"
    else fail "$3: $(tail -n2 "${WORK}/refuse.log")"; fi
}
C_LOCK="${WORK}/x64-20260101-0200.lock"
C_DIGEST="sha256:$(awk -F'\t' '$1 == "package" { print $5 }' "${C_LOCK}")"
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "package" { $5 = "0000000000000000000000000000000000000000000000000000000000000000" } { print }' "${C_LOCK}" >"${WORK}/wrong-row.lock"
refused "${WORK}/wrong-row.lock" "is not a package row of its lock" "a published archive its lock does not name"

# An archive under the current inputs that this tree does not build.
python3 - "${WORK}/foreign.deb" "$(git -C "${CLONE}" rev-parse HEAD)" <<'PY'
import io, sys, tarfile
out, commit = sys.argv[1:3]
def tgz(files):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode='w:gz') as t:
        for name, data in files:
            i = tarfile.TarInfo(name); i.size = len(data); i.mtime = 1767225600; t.addfile(i, io.BytesIO(data))
    return b.getvalue()
control = (f'Package: mica-board-x64\nVersion: 0.1.0+git{commit[:12]}-1\nArchitecture: amd64\n'
           f'Mica-Source-Repo: mica-boards\nMica-Source-Commit: {commit}\n').encode()
with open(out, 'wb') as f:
    f.write(b'!<arch>\n')
    for n, d in [('debian-binary', b'2.0\n'), ('control.tar.gz', tgz([('./control', control)])), ('data.tar.gz', tgz([('./usr/share/doc/mica-board-x64/copyright', b'foreign\n')]))]:
        f.write(f'{n + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(d):<10}`\n'.encode() + d + (b'\n' if len(d) % 2 else b''))
PY
F_SHA="$(sha256sum "${WORK}/foreign.deb" | cut -d' ' -f1)"
loc="$(curl -sf -D - -o /dev/null -X POST "${REG}/blobs/uploads/" | tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }')"
case "${loc}" in http*) ;; *) loc="http://${NAME}:5000${loc}" ;; esac
curl -sf -o /dev/null -X PUT -H 'Content-Type: application/octet-stream' --data-binary "@${WORK}/foreign.deb" "${loc}$(case "${loc}" in *\?*) echo '&' ;; *) echo '?' ;; esac)digest=sha256:${F_SHA}"
curl -sf -H "Accept: ${MT}" "${REG}/manifests/pool.x64.amd64.20260101-0200" |
    jq -c --arg d "sha256:${F_SHA}" --argjson s "$(stat -c %s "${WORK}/foreign.deb")" --arg t "mica-board-x64_0.1.0+git$(git -C "${CLONE}" rev-parse --short=12 HEAD)-1_amd64.deb" \
        '.layers[0].digest = $d | .layers[0].size = $s | .layers[0].annotations["org.opencontainers.image.title"] = $t' >"${WORK}/foreign.json"
curl -sf -o /dev/null -X PUT -H "Content-Type: ${MT}" --data-binary "@${WORK}/foreign.json" "${REG}/manifests/pool.x64.amd64.20260101-0250"
{
    printf '# mica-lock v1\npool\tamd64\tghcr.io/micaoss/mica-boards:pool.x64.amd64.20260101-0250@sha256:%s\n' "$(sha256sum "${WORK}/foreign.json" | cut -d' ' -f1)"
    printf 'package\tmica-board-x64\tamd64\t0.1.0+git%s-1\t%s\n' "$(git -C "${CLONE}" rev-parse --short=12 HEAD)" "${F_SHA}"
} >"${WORK}/foreign.lock"
refused "${WORK}/foreign.lock" "do not reproduce it" "an archive with unchanged inputs that the tree does not rebuild byte for byte"

# Last, as it removes a published blob: an archive the registry no longer serves.
curl -sf -o /dev/null -X DELETE "${REG}/blobs/${C_DIGEST}"
refused "${C_LOCK}" "does not download anonymously" "a published archive that is missing"

echo "package-reuse-test: ${PASS_N} passed, ${FAIL_N} failed"
[ "${FAIL_N}" -eq 0 ]
