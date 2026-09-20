# 20260920-0730-the-boot-logo-on-every-board-that-can-draw Adding the boot logo, and what it costs per board

- **status**: proposal
- **createdAt**: 2026-09-20 07:30
- **proposedBy**: tdpnmgkr, on the user's decision relayed by uj991oa2 (2026-09-20): "需要加，这样行为一致，后续还容易测试问题"
- **relatedTask**: 20260920-0720-the-logo-vt-policy-is-cx3576s

Nothing is turned on by this document. Every number below was measured on this
host with a control build, and every control that could be compared with a
published artefact reproduced it byte for byte.

## What the decision reverses, stated first

This repository concluded an hour earlier that the logind drop-in is
capability-conditional and that `NAutoVTs=0` on uefi-x64 would be harmful --
it would remove a working VT login to protect a logo that does not exist. **If
the board gains a logo, that objection dissolves**, because the policy then
has something to protect. The rule does not change; the boards that satisfy
its precondition do. The one board where the objection still stands is
uefi-arm64, which cannot draw at all.

## The four steps, per board, in this order

1. `CONFIG_LOGO=y` and `CONFIG_LOGO_LINUX_CLUT224=y`;
2. the `mklogo.py` render into `drivers/video/logo/logo_linux_clut224.ppm`,
   in the board's kernel prepare step;
3. `fbcon=logo-pos:center,logo-count:1` in the board's `BOARD_CMDLINE_ARGS`
   (the command line is forced, so this is signed with the kernel);
4. **and only then** the two policy files: the logind drop-in (`NAutoVTs=0`,
   `ReserveVT=2`) and the `getty@tty1` mask.

Out of order, a board gets an idle VT protecting nothing, or a logo a getty
covers.

## The mask, adopted from mica-build

A board that draws a logo ships `/etc/systemd/system/getty@tty1.service` as a
symlink to `/dev/null` beside its drop-in. The reason is mechanical: the
drop-in governs autovt on VT switch and does NOT disable `getty@tty1`, so
cx3576's quiet tty1 today is an accident of composition rather than a stated
policy, and a mask survives any later rule that enables tty1 because systemd
resolves a mask first. `consumers.json` already claims
`/etc/systemd/system/*.service` for the board packages, so the mask needs no
new declaration -- unlike the tty1 enablement, whose absence is the defect
mica-build is repairing on its side.

## One flag, so the four steps cannot drift apart

`BOARD_BOOT_LOGO=1` in `board.env`, and `tests/board-contract-test.sh`
asserts the equivalence: the flag is set **if and only if** the board's
fragments carry `CONFIG_LOGO=y`, its `BOARD_CMDLINE_ARGS` carries
`fbcon=logo-pos:`, its kernel prepare step renders the PPM, and its package
overlay carries both the drop-in and the mask. That is the "policy selected by
its own precondition" rule from the previous round, made into a check rather
than a convention -- five artefacts that can only be wrong together.

## The master lives in `common/kernel/`, and the tree proved why twice

cx3576's master is `boards/cx3576/flash/assets/splash.png`, a board-local
asset. Copying it per board would put the same artwork in the tree three
times AND require editing each board's build-context whitelist -- which I hit
twice while measuring:

- a board's kernel build context is a WHITELIST (`Dockerfile.dockerignore`:
  `*` then `!config/`), so a new input must be declared or `COPY` fails;
- and the context ROOT differs by family: the UEFI boards' context is
  `boards/<board>/kernel/` (`!splash.png`), the FIT boards' is
  `boards/<board>/` (`!kernel/splash.png`). I wrote the UEFI form on s905x5m
  and the build failed at `mklogo.py` with `FileNotFoundError` -- loudly,
  which is the right failure, but it is a failure that need not exist.

`common/kernel/` is already a named build context in BOTH families
(`--from=mica-common` for UEFI, `--from=common kernel/` for FIT), so a master
there needs **no whitelist edit on any board**, keeps one copy of the artwork,
and makes step 2 identical everywhere.

## What it costs, measured with controls

    board        artefact             control      with logo    delta
    uefi-x64     bzImage (compressed) 14992384 *   15012864     +20480    +0.137 %
    uefi-x64     + DRM_FBDEV_EMULATION             15033344     +40960    +0.273 %
    s905x5m      Image (uncompressed) 33065472     33327616     +262144   +0.79 %
    cx3576       --                   already has it
    uefi-arm64   Image (uncompressed) 24537600 *   26214912     +1677312  +6.8 %
                 (that is the whole display path, not a logo -- see below)

`*` the control reproduced the published artefact BYTE FOR BYTE:
`kernel.uefi-x64.20260916-0857` and `kernel.uefi-arm64.20260916-0857`. The
uefi-arm64 one is worth its own sentence: **a local CROSS build reproduced
what a native arm64 runner published**, which this repository had not measured
before and which makes the arm64 numbers here comparable with released bytes.

**And it corrects the shorthand this workspace has been using, mine included:
cross-versus-native is not the variable -- whether the two builds use the same
pinned toolchain is.** There are three cases to explain, not two: a container
running ON the target reproduces (the emulated arm64 pool matched the native
one byte for byte); a build that cross-compiles with a DIFFERENT toolchain
differs (mica-core's Rust, with its cross-toolchain note and different
`-C metadata`); and this one, the same pinned bsp compiler used once as a
cross and once natively, which agrees. The first and third differ in the
container's platform and agree in the toolchain; the second is the only case
where the toolchain moved. The comparison is real rather than two native
builds in disguise: `build.yml` maps arm64 to `ubuntu-24.04-arm` and the step
is named "the <board> kernel, native".

The two logo deltas differ by an order of magnitude for a boring reason: the
same 720x405 CLUT224 payload is about 291 KB of index bytes, which the x86
`bzImage` compresses to 20 KB and the arm64 `Image` carries uncompressed.
What lands on media for a FIT board depends on mica-build's packaging.

## uefi-x64 needs the second line, not only the logo

uefi-x64 draws on the EFI framebuffer and has `DRM_I915` and
`DRM_VIRTIO_GPU` built in with **no** `DRM_FBDEV_EMULATION`. A DRM driver
taking over the device usually removes the EFI framebuffer, so the logo would
likely appear and then vanish -- and "I saw a logo once" is a worse diagnostic
than today's blank tty1, which is the opposite of what the user asked for.
The proposal is therefore `CONFIG_LOGO` **with** `DRM_FBDEV_EMULATION` on that
board, +40960 bytes, and the QEMU session is where it gets confirmed.

## uefi-arm64: the board that cannot follow, and the price of making it

The trim was deliberate and its reasons are in the file: a section headed
"display, sound, media and input beyond the console" turns off `CONFIG_DRM`,
`CONFIG_FB`, `CONFIG_SOUND`, `CONFIG_MEDIA_SUPPORT` and the whole
`CONFIG_INPUT_*` class, under a header stating that this board boots
`root=/dev/dm-0` from a `dm-mod.create=` table with no initramfs, so only what
finds, verifies and mounts the root is built in and the rest is what "this
machine does not attach".

Reversing the display half minimally -- `FB`, `FRAMEBUFFER_CONSOLE`, `DRM`,
`DRM_SIMPLEDRM`, `DRM_FBDEV_EMULATION`, `DRM_VIRTIO_GPU`, `INPUT_KEYBOARD`,
plus the logo -- builds and costs **+1677312 bytes, +6.8 %**, eighty times the
logo on the board next to it. That is the price of consistency here, and it
buys a display on a machine class that is normally driven over serial.

**The recommendation is that it stays serial-only with no logo and no VT
policy, and that the user is told so rather than left to infer it** -- a
fourth board that cannot follow is a fine outcome; a fourth board nobody
mentioned is not. If the user wants it anyway, the measurement above is what
it costs and nothing else in the design changes.

## The rest of the cost

`common/kernel/` is in every board's kernel inputs, so all four kernels
rebuild at their next release. Three boards' resolved configs move; on the
UEFI boards that means `make <board>-kernel-config` and a reviewed diff (the
mechanism that refused my first experiment), while the FIT boards assert each
`=y` line at build time and record no resolved config. Then per-board
releases, then a mica-build round to re-pin.
