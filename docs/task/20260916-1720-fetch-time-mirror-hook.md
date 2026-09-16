# 20260916-1720-fetch-time-mirror-hook The fetch-time mirror, archives and git packs

- **status**: done
- **priority**: P2
- **owner**: tdpnmgkr
- **createdAt**: 2026-09-16 17:20

## Description

mica-res mirrors every third-party object this repository pins. The builders
consult that mirror before a row's own URL, so a build works where a vendor
host is slow, rate-limited or gone. The contract, both halves, came from
mica-res through the coordinator and is implemented here in one round.

    archives   GET <mirror>/blob/<sha256[0:2]>/<sha256>
    git trees  GET <mirror>/d/upstream/git/<name>/<commit>.json
               GET <mirror>/d/upstream/git/<name>/<commit>.pack.<NN>   in order

## What was built

- `common/scripts/mirror.sh`, the only place that knows the mirror's URL
  shape, and the three rules it keeps: a lock URL is never rewritten, the
  mirror is a source and never a trust anchor, and not reachable is not an
  error.
- `common/scripts/fetch-archive.sh <sha256> <url> <dest>` for `source` rows:
  mirror first, the row's URL on a miss, and the row's sha256 either way.
- `common/scripts/fetch-source.sh --name <git row>` for `git` rows: the
  manifest, then every chunk in order with its sha256 checked, then the joined
  pack's sha256, then `git index-pack --stdin` into a fresh repository,
  `.git/shallow`, and `git checkout --detach <commit>`. The rev-parse assertion
  that was already there is unchanged and is the acceptance test.
- `common/scripts/fetch-source.sh --tag <ref>`, so the two UEFI kernels can
  join the shared script without losing what their inline clone had: they
  clone the tag and the assertion catches a tag moved upstream. Every builder
  now fetches through the two scripts; the inline clone and the inline
  `curl | sha256sum -c` pairs are gone.
- `common/scripts/git-pack-manifest.py`, the manifest reader. python3 rather
  than jq: the build-env images carry python3 and no jq.
- `MICA_MIRROR` reaches the builders as a build argument through each board
  Makefile's `MIRROR_ARG` and, in CI, from the repository variable of the same
  name. It is absent from `tools/inputs.sh` on purpose: the bytes are the same
  either way, so the mirror must not move a component's inputs hash.

## What is deliberately NOT in this round

`boards/s905x5m/loader/package/Dockerfile` fetches the Amlogic packer with
BuildKit's `ADD --checksum` inside `debian:trixie-slim`, which carries no curl
and into which nothing is installed by design. Routing it through the hook
would mean installing a fetcher into a pinned image, so that one `source` row
keeps going to its pinned URL. The mirror holds the bytes if that changes.

## Measured

- `tests/mirror-hook-test.sh`, 25 assertions, in `make check` as `mirror-test`.
  It serves mica-res's contract from a local `http.server` and covers: a mirror
  hit, a 404 falling back, a refused connection falling back, an unreachable
  mirror falling back within a bounded wait, wrong bytes from the mirror being
  refused rather than fetched again, wrong bytes from the row's URL being
  refused, a mirrored pack imported and `fsck` clean at the pinned commit with
  `.git/shallow` written, a row that is not mirrored cloning upstream, a wrong
  chunk sha256, a manifest for another commit, a manifest of another schema,
  and that `locks/upstream.lock` is byte-identical after all of it.
- The real builders, locally, with no mirror: the `uefi-x64` kernel `src` stage
  (the new `--tag` path, 62.8 s) and the `s905x5m` U-Boot `source` stage, which
  fetches the three vendor toolchains through `fetch-archive.sh` and the U-Boot
  tree through `fetch-source.sh`.
- The caveat the contract warns about, in a real builder: `res.micaos.dev` does
  not answer from this workstation (DNS resolves to `2a06:98c1:3120::5`, TCP
  443 times out). With `MICA_MIRROR=https://res.micaos.dev` the `uefi-x64`
  source stage printed `uefi-x64-kernel f717995cb7dc is not mirrored` after
  3.178 s and finished normally. A mirror nobody can reach costs one connect
  timeout per object and changes nothing else.

## Cost

`boards/s905x5m/Makefile` carries `MIRROR_ARG`, and that file is in the
bluetooth producer's `PREPARE_INPUTS`, so `mica-s905x5m-bluetooth` is
`0.1.0-6`. Measured against `b30b26b`: it is again the only producer that
moved.

## Open with mica-res

`uefi-x64-kernel` and `uefi-arm64-kernel` pin the same linux-stable commit and
the bucket holds one copy. This implementation asks for its own row name, so if
only one of the two names is a manifest key, the other board falls back to
cloning -- correct, but it loses the mirror. The CI logs of the first run with
the variable set will say which, because every fetch prints whether it was
mirrored.
