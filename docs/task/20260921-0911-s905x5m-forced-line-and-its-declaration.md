# 20260921-0911-s905x5m-forced-line-and-its-declaration The board declared a command line its kernel was not built with

- **status**: done
- **priority**: P1
- **owner**: tdpnmgkr
- **createdAt**: 2026-09-21 09:11

`s905x5m.20260920-1536` shipped a kernel whose forced command line is not the
one the same release's `board.env` declares. Found when the user reported the
board, and relayed independently by the assembly, whose `s905x5m-prod` job is
the single failing one on its `main`.

## Measured, from the published components rather than the tree

The FIT boards commit a vendor input, so the kernel side was read out of
`kernel.s905x5m.20260920-1536` at the digest the release lock names:

    board.env              ... rdinit=/init fbcon=logo-pos:center,logo-count:1 vt.global_cursor_default=0
    kernel/dev/config      ... rdinit=/init mica.profile=dev      <- both tokens absent
    kernel/prod/config     ... rdinit=/init mica.profile=prod     <- both tokens absent

cx3576 at the same release agrees with its own `board.env`, tokens included,
so this is one board and not the shared kernel stage.

**On a FIT board this is not cosmetic.** The kernel is built with
`CMDLINE_FORCE`, so the built-in line is what the device boots with and no
bootloader can add a missing token later.

## Which side was wrong, and how its own release answers that

The kernel. Four of the five artefacts `BOARD_BOOT_LOGO=1` moves shipped in
that release -- `CONFIG_LOGO=y` and `CONFIG_LOGO_LINUX_CLUT224=y` are in the
published config, the PPM render is in `kernel/hooks/prepare.sh`, and the
logind drop-in and the `getty@tty1` mask are in the package overlay. Only the
command line did not. A board that did not want the tokens would not be
carrying the other four.

## Why nothing caught it

- This board keeps `CONFIG_CMDLINE` in `kernel/config/signed-boot.fragment`;
  cx3576 keeps it in its committed vendor config. **I edited `board.env` and
  not the fragment.**
- `common/kernel/set-profile.sh` takes the line out of the resolved `.config`
  and appends the profile token. **It never reads `board.env`** -- by design,
  and that design has no second reader.
- The board's `kernel/hooks/assert.sh` compares the fragment against the
  resolved config. Both were stale together, so it passed: **the same
  statement twice is not a check.**
- cx3576 has `tests/kernel-cmdline-test.sh` asserting the two agree. **This
  board had no such test**, which is the whole of the gap: the instance was
  repaired on one board when the class had two members.
- The only gate that sees it is `mica-build:build/src/kernel-package.ts:149`,
  in another repository, after a product build has started. It is correct as
  written and must not be relaxed: relaxing it would authenticate a kernel
  whose forced line is not the one the board declares.

## The repair

`signed-boot.fragment` now carries `board.env`'s line, and
`boards/s905x5m/tests/kernel-cmdline-test.sh` asserts they are equal, that the
line is forced, that it carries no profile token, and that both logo tokens
are present. **It was written first and watched fail on the unfixed tree**,
printing both lines. `make kernel-cmdline-test` now runs both FIT boards.

Swept for the same shape: neither UEFI board has an in-kernel line to diverge
from (`uefi-x64` has no `CONFIG_CMDLINE`, `uefi-arm64` has `CONFIG_CMDLINE=""`,
neither forces), so the assembly's UKI `.cmdline` written from `board.env` is
their single source. s905x5m was the only member.

**A new release is required for the fix to reach anything**; the bundle at
`20260920-1536` cannot be corrected in place.
