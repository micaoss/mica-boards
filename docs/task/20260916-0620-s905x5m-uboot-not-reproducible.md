# 20260916-0620-s905x5m-uboot-not-reproducible The s905x5m U-Boot is not reproducible

- **status**: open
- **priority**: P2
- **owner**: tdpnmgkr
- **createdAt**: 2026-09-16 06:20

## Description

Two builds of the s905x5m `uboot` component from the same inputs produce
different bytes. Measured between the releases `s905x5m/20260915-1926` and
`s905x5m.20260916-0558`: the component's inputs hash (`tools/inputs.sh uboot`)
was unchanged, the toolchain came from the same pinned Ubuntu snapshot
(`locks/upstream.lock` `ubuntu-<suite>` rows, `20260915T000000Z`) and the same
pinned vendor trees, and no commit between the two releases touched
`boards/s905x5m/loader/` or `common/uboot/`. Three files came out different:

- `uboot/u-boot.bin.signed` (6c41bdd55a80... -> 1572ae396fe4...)
- `uboot/u-boot.bin.sd.bin.signed` (3aff13826d4b... -> 325dd5ee0655...)
- `uboot-package/update.img` (be7dfe9d3d64... -> 42a868b5f068...), and its
  `update.img.sha256` with it -- the recovery container packs the two binaries
  above, so it follows them rather than being a second defect.

Everything else of that release matched byte for byte: the `board`, `kernel`
and `firmware` components of all four boards, and cx3576's `uboot`.

Why it surfaced only now: a board release reuses an unchanged component by
digest (`tools/reuse.sh`), so the s905x5m `uboot` component was published once
and re-tagged at every later release without being rebuilt. The dot-form
cut-over made the reader select releases by the `<board>.` prefix, so the
slash-form releases were invisible and the component was built again -- the
first second build of it since it was created.

Same class as the s905x5m kernel defect fixed by kernel patch 0018
(`common_drivers` Makefiles compiled a wall-clock `BUILD_TIME`, so even two
clean kernel builds differed). The suspects here are the vendor U-Boot build
embedding a build time, a build host or a `git describe` result, and the FIT
or signing step recording a timestamp.

## ActiveForm

Finding what the s905x5m U-Boot build embeds that is not its inputs

## Dependencies

- **blocked by**: the uefi rename round (in progress)
- **blocks**: nothing today -- `boards/s905x5m/board.env` has
  `BOARD_RELEASE_TARGET=0`, so no product is built from this board

## Notes

2026-09-16 06:20: opened from the dot-form cut-over comparison; reported to the
coordinator (uj991oa2). The artifacts published in `s905x5m.20260916-0558` are
valid and signed; they are simply not reproducible from their inputs, so a
later rebuild cannot be proven to be the same U-Boot.

Where to start: build `make -C boards/s905x5m uboot` twice in a row on one host
and diff the two `_out/s905x5m/uboot/` trees (the build is about 2.5 minutes
locally), then bisect the difference with `strings`/`cmp` as patch 0018 was
found. A byte-identity check like `make <board>-kernel-profile-test` should
come out of it, so the answer is kept.
