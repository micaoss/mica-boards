# 20260920-cx3576-first-hardware-capture What the first cx3576 console capture establishes

- **status**: open
- **priority**: P1
- **owner**: tdpnmgkr
- **createdAt**: 2026-09-20

## What it is

The first console capture of Mica OS running on cx3576 silicon, reported by
the user on 2026-09-20. 1256 lines, sha256
`26fc740724a1c11962b3a0a696f80f617e5906ee3b1c5bf37d080b0341f267ef`. Every
statement below was read out of that file here, not taken from a summary.

**It has no durable home yet.** It arrived as a coordination-session upload,
and an evidence note may not cite one. It also carries the unit's SoC serial
(`rockchip-cpuinfo cpuinfo: Serial: d6aa8e0ed78890f8`), from which this
project derives the hostname and MAC, so where it is kept is a decision about
publishing a device identity and not only about storage. Until that is
decided, this record cites the file by its sha256.

## What the capture establishes, verified line by line

- **The vendor loader executed our signed FIT on real silicon.** Three
  `Verifying Hash Integrity ... sha256,rsa2048:mica+ OK` lines (kernel, fdt,
  ramdisk), at lines 95, 111 and 128.
- **The forced command line is the one this repository signs**: line 176
  carries `dm_verity.require_signatures=1 ... mica.profile=prod`, so this unit
  ran the **prod** profile.
- **The kernel is the one we published, by identity**: line 151 is
  `Linux version 6.1.115 (mica@mica-build) ... aarch64-linux-gnu-gcc (Ubuntu
  13.3.0-6ubuntu2~24.04.1) 13.3.0 ... #1 SMP @1577836800`. `6.1.115` is
  exactly the `kernel/prod/kernel.release` published by
  `cx3576.20260917-1007`, which `mica-build`'s `cx3576.20260919-2356`
  (`f46b64a6`) pinned -- so the run binds to published bytes through the
  locks, not to "the latest build". `#1 SMP @1577836800` is our
  `KBUILD_BUILD_VERSION=1` and `SOURCE_DATE_EPOCH`, and the compiler is the
  bsp image's Ubuntu gcc 13.3.0: the reproducibility settings and the pinned
  toolchain, visible on hardware.
- **Our PID 1 ran and authenticated the deployment**: `mica-init: selected
  deployment 745f0b9f...` (line 847) and `verified deployment ...; support
  mounted before system init` (line 862).
- **The system reached a healthy state**: `mica-health.service` -- the unit
  that confirms the authenticated deployment -- finished (line 1243),
  `mica-status-led` ran boot red to ready blue (line 1245), and the login
  prompt appeared.
- **The unit, as far as the log names it**: machine model `CX3576-Z (RK3576)`,
  eMMC `mmcblk0: mmc0:0001 SCA128 116 GiB` in HS400 Enhanced strobe with
  `mmcblk0boot0/boot1/rpmb`, 8 GiB LPDDR4X at 2112 MHz.

## What it does NOT establish, and this is the part to get right

- **It is not row 1 and it is not row 2.** The capture opens at a U-Boot
  prompt with `=> reset` (lines 2-3) and BL31 reports `soc warm boot, reset
  status: 0x1` (line 60). Row 1 is power-on from cold, repeatably. Row 2 is
  "reboot from a running system"; this reset was issued from the LOADER
  console, and nothing in the capture says what ran before it. So it is
  neither row, and writing either one from this file would be the same
  mistake in two directions. What is needed is one capture beginning with
  power applied to a cold unit (row 1, two or three times, each with the
  health readout) and one beginning with `reboot` typed at a running Mica OS
  prompt (row 2).
- **It is not row 13.** Row 13 is a documented flash onto a blank unit over
  the board's own transport; this unit was already provisioned.
- **The radio SKU is not in it.** The log shows the BT rfkill platform glue,
  `mica-bt.service` attaching HCI over UART and `bluetooth.target` reached --
  no chip identification, no association, no transfer. The dossier's
  `AIC8800D80` remains a claim about the SKU, not an observation. Row 6 gets
  nothing beyond `r8168: eth1: link up` (line 1251), which is link, not
  transfer.
- **Rows 3, 4 and 12 -- A/B update, power-cut and recovery -- are untouched**,
  and they are the three that make a board supported rather than booting.

## The assurance ladder does not move, and one sentence in it does

`mica:docs/boards/assurance.md` says of I3 that the software results "do not
establish enforcement on an untested physical board". The positive half is now
observed: on 2026-09-20 the vendor loader verified our key on real silicon
(`rsa2048:mica+ OK`). The negative half -- an altered or unsigned FIT refused
on the same bench -- is absent, and I2's authenticated-update evidence is
absent, so `boards/cx3576/evidence.json` stays **I1**. Its `qualification`
records the observation and its date; the grade is unchanged and nothing in
this record claims the board is qualified.

## Still to be asked of the person at the bench

1. A cold-boot capture, two or three power-on cycles, each ending with the
   health readout (row 1).
2. A capture beginning with `reboot` at a running prompt (row 2).
3. `uname -r`, `cat /proc/cmdline` and the micad health output pasted into the
   same log, so the run is self-identifying without cross-referencing.
4. The board revision, the eMMC part number as printed on the part (the log
   gives the card's `SCA128` name, not the manufacturer's part) and the radio
   module SKU.
5. Where the capture may be kept, given the SoC serial it contains.
