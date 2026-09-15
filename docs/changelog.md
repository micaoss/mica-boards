# Changelog

## 2026-09-15 [progress]

Flashing formats (user decision): every board declares what it is flashed with in
`boards/<board>/images.tsv` (`# mica-boards images v1`; rows `image <kind> <packer>
<runtime image> <suffix>`), carried in its board component and covered by its
inputs hash. All four boards declare `image disk builtin mica-build-env:base img`.
`IMAGE_KINDS` is gone from `board.env`; `board-contract-test` requires the disk row
with `builtin`, no other `builtin` kind, unique kinds and suffixes, and runtime
images named by `locks/mica-build-env.lock`.

## 2026-09-15 [progress]

Board components (user decision, mica 1cd0fdd): a board release publishes its
components as separate artifacts, `<component>.<board>.<YYYYMMDD-HHMM>` --
board, kernel, and uboot and firmware where the board has them
(`tools/component.sh`) -- each annotated with `mica.component` and `mica.inputs`,
the sha256 of everything that determines it (`tools/inputs.sh`). A component
whose inputs equal the same component of the board's latest release is reused by
digest and not built (`tools/reuse.sh`, `tools/publish-components.sh`). The lock's
board rows are `board <board> <component> <arch> <reference>`; `outputs.tsv` names
`file <component> <path>`; `mica-kernel-<board>` is retired. `build.yml` builds
each board's kernel natively on its architecture's runner and U-Boot on x86-64
(the FIT host tools the assembly runs there; s905x5m's i386 packer).

## 2026-09-15 [progress]

Releases are per board (user decision): `gh release create <board>/<YYYYMMDD-HHMM>`
builds, gates and publishes that board alone -- `pool.<board>.<arch>.<YYYYMMDD-HHMM>`,
`board.<board>.<YYYYMMDD-HHMM>` and a `mica-boards.lock` whose release row is
`<board>/<YYYYMMDD-HHMM>`. `boards/boards.tsv` lists the supported boards, one
row each (architecture, boot backend); `boards/<board>/outputs.tsv` names the
board's pool packages and bundle files and travels in its bundle. `tools/boards.sh`
reads them for `build.yml` (the plan job), `make pool POOL_BOARD=`, the package
gate (`--board`), the publishers, `release-lock.sh`, `make offline` and
`board-contract-test`. CI keeps building every board.

## 2026-09-15 [progress]

Release lock (mica:docs/design/release-lock.md). Inputs are in `locks/`:
`locks/mica-build-env.lock` with `locks/pins/mica-build-env.pin` (mica-build-env
`20260915-0138`) gives every image, build-env images by name and third-party
images by their upstream rows (`tools/from.sh`); `locks/upstream.lock` pins the
kernel, U-Boot and rkbin trees as git rows and the s905x5m toolchains and
packer as source rows (`tools/upstream.sh`). `build-env-image.lock`,
`build-env-release`, `base-images.env`, every `sources.env` and the UEFI
`kernel/versions.env` are gone; the UEFI kernels check their tag's commit.
`tools/check-lock.sh` implements the file rules, `tests/locks-test.sh` runs it
over the specification's vectors. A release carries `mica-boards.lock`
(release, pool, package and board rows) and `SHA256SUMS` only
(`tools/release-lock.sh`), written after every pool and bundle reads back
anonymously; both publishers refuse a tag holding another manifest digest.

## 2026-09-14 [progress]

The project name is mica everywhere in the tree: the shared inputs are
`common/kernel/mica-required.fragment` and `common/uboot/mica-records.h`; the
build contexts `mica-common`, `mica-trust` and `mica-boot-trust`; the verity
anchor `certs/mica-verity-anchor.pem`; the U-Boot policy `MICA_FILE_BOOT`
(`loader/mica-file-boot.c`, `loader/build-mica.sh`, stage `artifact-mica`),
its environment key `mica_entries` and the `/chosen/mica,deployment-id`
property; the cx3576 targets `uboot-mica` and `flash-mica`; the buildx
builders `mica-<arch>`. The FIT boards build one kernel per image profile
(`kernel/dev/`, `kernel/prod/`), each forcing `mica.profile=<profile>` on its
command line. The build-env images are those of mica-build-env
`20260914-1129` (`build-env-image.lock` and `build-env-release` replaced
whole).

## 2026-09-14 [progress]

Workspace rules and mica-build-env `20260914-0128`
(`20260914-0514-workspace-rules-and-build-env`). The images come from
`build-env-image.lock` (verified against the release's `SHA256SUMS`,
recorded in `build-env-release`) and `base-images.env`, through
`tools/from.sh`; the `build-env/` source pin, `tools/deps.sh` and `deps/` are
gone. Packaging, the package gate and the publisher are this repository's own
under `tools/deb/` and pack in `IMAGE_MICA_BUILD_BASE`. Releases are
`gh release create <YYYYMMDD-HHMM>`: `release.yml` builds that tag and
publishes `pool.<arch>.<release>` and `board.<board>.<release>`; `ci.yml` runs
the gates and, through the reusable `build.yml`, the BSP build on x64 (cross)
and one native pool job per architecture with its package gate. The cx3576
kernel hook reads the boot-logo master at `flash/assets/splash.png`, where the
board layout moved it (the kernel build had failed since).

## 2026-09-14 [progress]

The boot split, step 3: the inputs this repository took from the `mica-boot`
source pin are its own, and the pin is gone. `families/common/kernel/` holds
`mica-required.fragment`, `kernel-config-test.sh` and `export-regdb-certs.py`;
`families/common/uboot/` `mica-records.h` and `embed-fit-trust.sh`;
`families/common/package/` `fstab.in` and `copyright` (taken from
`mica-boot` 302d9cc `common/`; only comments naming paths and key provenance
changed). `families/common/trust/stage.sh` is the
certificate-only half of the former `verity-tool.sh stage`: it validates a
public certificate bundle in the pinned OpenSSL image and stages it for the
kernel and U-Boot builds; signing and every private key belong to the
assembly, and nothing here generates keys. `tests/trust-stage-test.sh`
(`make trust-stage-test`, docker) covers it.

## 2026-09-13 07:40 [progress]

Phase 1 of `mica:20260913-0416-board-product-build-architecture`, board
contract v2 and the family layer. Every `board.env` declares
`BOARD_FEATURES`, `BOARD_FAMILY` and `IMAGE_KINDS`; the package manifests
moved here from the assembly as `<board>/manifests/` and travel in the
`mica-kernel-<board>` bundle; `bsp/containers.env` is gone (the product
decides features). `families/` holds what the boards of one SoC line
share: `uefi` (x64, virt-arm64: one kernel Dockerfile), `rockchip`
(cx3576) and `amlogic` (s905x5m), each with its Dockerfiles, configure and
build scripts and source pins; a board keeps its configuration, device
tree, patches, firmware and the hooks the family calls, and names its
files in `bsp/bsp.env` (`families/README.md`). Proof: every board's kernel
rebuilt through its family byte-identical to a build of the same pins
before the change (config, release, modules, System.map, DTB; the
s905x5m `Image` carries a 25-byte vendor build stamp that differs between
any two builds, and its `modules.tar` now pins mtimes and order like the
other families'); cx3576 and s905x5m U-Boot likewise.
`tests/board-contract-test.sh` asserts the contract in `make check`.

## 2026-09-13 19:30 [progress]

Created from `boards/{x64,virt-arm64,cx3576,s905x5m}/` of `mica-build`
(each kept through `git subtree split`, briefly a repository of its own,
then brought in here with that history under `<board>/`). The BSP builds
take the boot tooling from the `mica-boot` source pin at `boot/` and the
shared inputs from `boot/common`; a `mica-kernel-<board>` producer per board
packs the BSP outputs for the assembly. Published together as
`build-<commit12>` (`20260913-1600-split-boot-and-boards`).
