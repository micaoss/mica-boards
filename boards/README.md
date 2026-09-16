# Boards

A board is one directory under `boards/` that carries its whole build: the
board definition, the kernel and U-Boot builds with their upstream source
pins, the package inputs, the evidence and the board's tests. Nothing of a
board's build lives in another board; what every board takes identically
comes from the top-level `common/`. `tools/new-board.sh <new> --from
<nearest>` copies a board, build included, and the copy is then the new
board's own. `tests/board-contract-test.sh` holds every board to this layout.

`boards/boards.tsv` lists the supported boards, one row per board, for this
repository's tools and for consumers (`tools/boards.sh`); a board directory is
supported only when listed. After the header line `# mica-boards boards v1`,
tab-separated and sorted by board:

```
<board>	<arch>	<boot backend>          the directory boards/<board>/, its MICA_ARCH and BOOT_BACKEND
```

What a release of a board outputs is the board's own `boards/<board>/outputs.tsv`,
which travels in its board component; a release must output exactly what it
names. After the header line `# mica-boards board outputs v1`, tab-separated rows
sorted by kind (package, file), then value:

```
package	<package>                  an archive of its pool, pool.<board>.<arch>.<release>
file	<component>	<path>           a file of one component artifact, <component>.<board>.<release>, by its
                                   path in the assembled board tree: board (board.env, evidence.json, images.tsv, manifests/,
                                   outputs.tsv, trust/), kernel (kernel/), uboot (uboot/, uboot-package/),
                                   firmware (firmware/, component-copyright)
```

```
boards/<board>/
  board.env             the board definition: BOARD_FEATURES, MICA_ARCH, the boot backend, ...
  images.tsv            what the board is flashed and updated with: image|update <kind> <packer> <runtime image> <suffix>
                        (image disk builtin and update full mandatory; builtin rows name - as runtime image)
  outputs.tsv           what a release of the board outputs: its pool's packages and each component's files
  Makefile              sets BOARD; the kernel and firmware targets and the board's own (flashing, a recovery package, a userland bridge)
  bsp.env               FIT boards: what the builds take (KERNEL_EXPECT, KERNEL_CONFIG, KERNEL_DTB, KERNEL_DTB_ARTIFACT, UBOOT_DEFCONFIG, DDR_BLOB, BL31_BLOB, KERNEL_FRAGMENTS)
  kernel/
    Dockerfile          the kernel build; context = the board directory (FIT) or kernel/ (UEFI)
    Dockerfile.dockerignore
    configure.sh        FIT: the resolved configuration and its floor
    build.sh            FIT: the compile and the artefacts
    config/             the committed configuration and fragments
    dts/, patches/      FIT: device tree and patches (with a series file)
    hooks/              FIT: the board's hooks (below)
  loader/
    Dockerfile          FIT: the U-Boot build; context = loader/
    ...                 the loader policy: build scripts, patches, tests, vendor loader
  manifests/, package/, firmware/, evidence.json, tests/, extras/
```

## The kernel command line and the image profile

The product's image profile is one `mica.profile=dev|prod` token on the signed
kernel command line, written for both profiles (mica docs decision
2026-09-14-no-image-profile-packages).

- **FIT boards (cx3576, s905x5m).** The kernel forces its built-in command line
  (`CONFIG_CMDLINE_FORCE=y`), so the token is built into the kernel: `make
  kernel` builds one kernel per profile, each with `CONFIG_CMDLINE` =
  `BOARD_CMDLINE_ARGS` + ` mica.profile=<profile>` (exactly one token;
  `common/kernel/set-profile.sh` sets it and refuses a board line that already
  names `mica.profile` or `mica.recovery`), into `_out/<board>/kernel/dev/` and
  `_out/<board>/kernel/prod/`, from one compile: dev is built whole and prod only
  relinks the Image in the same tree, with the modules, device tree and
  regulatory certificates of that build (none reads the command line).
  `make kernel-profile-test` builds prod alone, clean, and requires every file
  to be byte-identical to the relinked one. The board's kernel component carries both as
  `kernel/dev/` and `kernel/prod/`, each a complete kernel
  directory (Image, device tree, config, System.map, kernel.release,
  modules.tar, regdb-certs.pem); the assembly takes `kernel/<profile>/` for a
  product. Each profile's kernel is reproducible on its own.
  **Enforced:** U-Boot carries the FIT public key in its control DTB with
  `required = "conf"` (`common/uboot/embed-fit-trust.sh`) and is built with
  `FIT_SIGNATURE` (cx3576 also `FIT_FULL_CHECK`) and without
  `LEGACY_IMAGE_FORMAT`, `CMD_BOOTI` and `USE_PREBOOT` (`loader/build-mica.sh`),
  so its boot command boots only a FIT whose signed configuration verifies, and
  the kernel ignores any bootloader-supplied arguments: on the boot path the
  command line, profile token included, cannot be replaced by an unsigned image.
  **Not enforced against console access:** both U-Boots keep an interactive
  console (`BOOTDELAY=1`, `CMDLINE`) with `fdt`, `md`/`mw` (and `go` on
  cx3576), so someone at the serial console can alter the in-memory control DTB
  or run an unsigned binary; the same U-Boot serves both profiles. Also not
  covered: verification of U-Boot itself by the SoC boot ROM, which this
  repository does not enable or assert.
- **UEFI boards (uefi-x64, uefi-arm64).** The kernel has no built-in command line
  (`CONFIG_CMDLINE=""`) and the kernel component carries one `kernel/`. The assembly signs
  the UKI with `.cmdline` = `BOARD_CMDLINE_ARGS` + the profile token; whether a
  modified UKI is refused depends on UEFI Secure Boot, which is the assembly's
  and the platform's (mica-build).

`common/` is what every board takes unchanged:

```
common/
  scripts/   fetch-source.sh, apply-patches.sh, buildx.sh (the builders' shared steps);
             buildx.sh (docker buildx build, with the CI cache of a build's third-party prefix stage)
  kernel/    mica-required.fragment (the shared kernel floor), floor-check.sh (the floor, asserted after olddefconfig),
             kernel-config-test.sh (the committed configs against it), export-regdb-certs.py (the regulatory
             database certificates the kernel trusts), mklogo.py (the boot-logo renderer); the kernel builds' `mica-common` context
  uboot/     mica-records.h (the signed-boot record format), embed-fit-trust.sh (the FIT trust into the control DTB);
             the U-Boot builds' `mica-common` context
  trust/     stage.sh with stage-inner.sh: validates a public certificate bundle (PEM certificates only, no private key,
             parseable by OpenSSL) and stages it as the `mica-trust` / `mica-boot-trust` context; VERITY_TRUST_CERT and
             FIT_TRUST_CERT are the only trust inputs
  package/   fstab.in and copyright, the board package render and copyright fallback (the producers' `common` context)
```

Each board's copy of its build is its own: the two UEFI boards (uefi-x64,
uefi-arm64) carry the same kernel Dockerfile today, and no check holds the
copies identical -- a change to one board's build is that board's change.
The prefix stage of every kernel and U-Boot Dockerfile (`source`, the UEFI
`src`) holds only the toolchain and the upstream source; CI caches that stage
alone (`common/scripts/buildx.sh`).

## The hooks

A FIT board's kernel build calls these scripts from its `kernel/hooks/` when
they exist. Each receives the source tree first; CROSS_COMPILE is in the
environment where the build sets it.

| Hook | When | Arguments | For |
|---|---|---|---|
| `prepare.sh` | after the patches, before the configuration | `<src> <board-dir> <common/kernel>` | what a board derives into the tree (cx3576 renders its boot logo) |
| `configure.sh` | after `LOCALVERSION_AUTO` is disabled, before the floor is merged | `<src>` | the board's `scripts/config` edits |
| `assert.sh` | after `olddefconfig` and the shared floor check | `<src>` (s905x5m: `<src> <config-dir>`) | the board's own required and refused options |
| `verify.sh` | after the build and the device tree | `<src> <dtb>` | source and device-tree assertions |
| `modules.sh` (s905x5m) | after the in-tree modules are installed, before depmod | `<src> <install-root> <board-dir>` | the board's out-of-tree modules |
| `modules-verify.sh` (s905x5m) | after depmod | `<module-dir>` | the indexed set carries them once |

The artefacts are reproducible (`KBUILD_BUILD_*` and `SOURCE_DATE_EPOCH` are
pinned, and the kernel and U-Boot builders take their toolchain from the
digest-pinned mica-build-env `bsp` image of `locks/mica-build-env.lock` rather
than installing it): the proof of a change to a board's build is its kernel and U-Boot
byte-identical to the build before it, where the change was not meant to move
them.
