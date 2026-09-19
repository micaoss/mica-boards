# 20260919-2130-s905x5m-as-a-release-target What opening s905x5m for release costs

- **status**: open
- **priority**: P2
- **owner**: tdpnmgkr
- **createdAt**: 2026-09-19 21:30

## The question

`boards/s905x5m/board.env` carries `BOARD_RELEASE_TARGET=0`; the other three
boards carry `1`, and `mica-build` derives publish and indexed from it. What
does flipping it cost? Measured, not estimated. Nothing is flipped here: the
decision is the user's.

## 1. What the flag costs in inputs: one package bump

Measured against a clean clone with the flag flipped and nothing else changed.

    component  board     inputs bea2041aea98 -> f8e72bac1a07   REBUILDS
    component  kernel    unchanged  ffa2ecc280c9              reused by digest
    component  uboot     unchanged  485ebd3eb2f5              reused by digest
    component  firmware  unchanged  bfafea529122              reused by digest

    producer   board@s905x5m  80b6ca1d8466 -> 10d2746bec18    mica-board-s905x5m
    every other producer                                       unchanged

`board.env` is a file of the `board` component (`outputs.tsv`) and the
`FOR_EACH` instance file of the board producer, so the flip costs exactly one
version bump, `mica-board-s905x5m` `0.1.0-2` -> `0.1.0-3`, and one component
rebuild. It does **not** reach the bluetooth producer: that producer's
`PREPARE_INPUTS` is `boards/s905x5m/Makefile boards/s905x5m/bsp.env
boards/s905x5m/userland`, and `board.env` is in none of them.

## 2. The U-Boot, and a correction to how it was read

The recorded property is right --
[20260916-0620](20260916-0620-s905x5m-uboot-not-reproducible.md), confirmed
twice -- but "every s905x5m release will show the loader as changed" does not
follow from it. Reuse is decided by INPUTS, not by bytes (`tools/reuse.sh`
compares the component's `mica.inputs` against the board's latest release), so
a release whose U-Boot inputs did not move republishes the same digest without
rebuilding, and nothing differs. The flip itself is an instance: it does not
touch the U-Boot inputs, so the first release after it reuses the loader
unchanged.

What is true is narrower and permanent: a release whose U-Boot inputs DID move
rebuilds it, and that rebuild is never byte-identical. The inputs are
`boards/s905x5m/loader`, `bsp.env`, the board `Makefile`, `common/uboot`,
`common/scripts`, `common/trust`, the two vendor git rows, the toolchain
source rows, the bsp image digest and the boot certificate.

The cost when it does move, from the published component of
`s905x5m.20260916-0857`: four of its twelve files differ and the rest are
identical and deduplicated by the registry.

    uboot/u-boot.bin.signed          3321856
    uboot/u-boot.bin.sd.bin.signed   3322368
    uboot-package/update.img        10267648
    uboot-package/update.img.sha256       77
                                 = 16911949 bytes, 16.13 MiB per such release

Frequency is a function of how much the loader is touched, not of the calendar:
in the week of 2026-09-16 its inputs moved three times (the bsp switch, the
packer platform, the mirror hook); in a week that does not touch the loader it
moves zero times.

## 3. What else is true of this board and not of cx3576

- **It has no `evidence.json`.** The three release targets each carry one;
  s905x5m does not, and `mica-build`'s release manifest REQUIRES it: it reads
  `board-evidence.json`, validates `schemaVersion` 2, the board name, a known
  `bootAssurance`, a non-empty `qualification`, at least one `evidenceRef` and
  `physicalBoundaries`, and the manifest's `bootAssurance` comes from it
  (`mica-build:build/src/release-manifest.ts`). This is the one piece of work
  that must precede a flip, it is in this repository, and it is a document to
  be written honestly rather than a gate to be passed: what is tested, what is
  not, and where the physical boundaries are.
- 15 kernel patches against cx3576's 6, one of which
  (`0018-common-drivers-build-time-from-source-date-epoch.patch`) exists only
  to stop a vendor Makefile stamping wall-clock time into the kernel.
- two extra producers and four extra packages (`mica-s905x5m-bluetooth`,
  `mica-s905x5m-wifi`, `mica-s905x5m-wireless`, `mica-bm201-front-panel`);
  cx3576 has no `extras/` at all. Nine packages in its pool against cx3576's
  four, so nine version-guard surfaces against four.
- the only producer in the repository with a `PREPARE` hook that COMPILES
  vendor sources (`boards/s905x5m/extras/bluetooth`), and the only package
  whose version has been bumped by edits elsewhere in the board -- three times
  in the week of 2026-09-16.
- every `source` row of `locks/upstream.lock` is this board's: three vendor
  toolchains and the closed-source i386 Amlogic packer. cx3576 needs none.
- CI cost per full build, from run 35469299367: kernel 1027 s and U-Boot 262 s
  against cx3576's 703 s and 131 s -- 1289 s against 834 s, 55 % more runner
  time per release.
- its kernel fetch needs `--http1` and `--submodules`; the vendor host stalls
  on HTTP/2.
- no `flash/` directory and no `make flash-*` targets: cx3576 has a maskrom
  path with tooling and tests, s905x5m's recovery path is the `update.img`
  container and `aml_sdc_burn`.

## What is NOT a reason to withhold the flip

Physical qualification. `mica:docs/boards/support-tiers.md` puts cx3576 and
s905x5m at the same tier with "physical rows not tested" for both, and cx3576
is a release target. Opening a board for release does not claim it works on
hardware; the evidence document is where that distinction is stated, which is
why writing it is the prerequisite rather than testing the hardware.
