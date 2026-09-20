# 20260920-0627-kernel-capabilities-beside-each-board The floor, made legible to another repository

- **status**: proposal
- **createdAt**: 2026-09-20 06:27
- **proposedBy**: tdpnmgkr, at the coordinator's authorisation (uj991oa2, 2026-09-20): write the feature-to-symbol mapping for `containers` with all three repositories named; nothing is turned on until the user decides
- **relatedTask**: 20260920-the-floor-and-the-declared-features

## Context

A product declares features (`mica-build:products/<product>/product.env`,
`FEATURES="micad mqtt containers ..."`). A board ships a kernel. Nothing
compares the two, and the consequence was measured on 2026-09-20: every
product of every board declares `containers`, and

- `CONFIG_MEMCG` is absent on uefi-x64, so a container's memory cannot be
  bounded there -- `podman run --memory` fails at the write to `memory.max`
  (mica-podman traced it), and `podman stats` reports an empty memory number
  with no warning;
- `CONFIG_CFS_BANDWIDTH` is absent on BOTH UEFI boards, so no `cpu.max` and no
  CPU quota.

Neither is a defect in any one repository. The floor
(`common/kernel/mica-required.fragment`) states what the SYSTEM needs and is
asserted against every board's resolved config; the feature list states what a
PRODUCT offers; nothing joins them.

## What this repository already has, and it is the half that works

The floor is asserted on the RESOLVED config, not on the committed one
(`common/kernel/floor-check.sh`, and the same three checks inline in the UEFI
Dockerfiles), and `kernel/config/<board>.config` is a reviewed input that the
build refuses to differ from. Measured while costing the symbols: adding one
line to a fragment made the build FAIL until every affected board's config was
re-recorded and the diff put up for review. **A floor change here cannot be
silent** -- which is the property the composer defect of the same evening
showed was missing elsewhere, and it is already built.

What is missing is only the join, and the join needs a vocabulary.

## Proposal

**1. A capability vocabulary, owned here, one line per capability.**
`common/kernel/capabilities.tsv`, rows `<capability> <symbol>[ <symbol>...]`,
where every symbol must be `=y` (or `=m` with the module shipped) in the
RESOLVED config for the board to provide that capability. Only this
repository can say what a requirement means in a kernel config, so the
mapping lives here; the REQUIREMENTS come from the repository that makes the
call, named in a comment on each row.

Draft for `containers`, split so a product can need part of it. Rows marked
`[confirm]` need mica-podman to state what the engine and its helpers
actually call, as it did for the memory case:

    container-runtime   CGROUPS CGROUP_PIDS CGROUP_DEVICE CGROUP_BPF SECCOMP \
                        NAMESPACES USER_NS PID_NS NET_NS IPC_NS UTS_NS OVERLAY_FS
    container-memory    MEMCG                       # podman --memory -> memory.max
    container-cpu       CFS_BANDWIDTH FAIR_GROUP_SCHED CGROUP_SCHED   # --cpus -> cpu.max
    container-io        BLK_CGROUP                  # [confirm] --blkio-weight
    container-network   BRIDGE VETH NF_TABLES NF_NAT   # [confirm] netavark's actual set
    container-rootless  USER_NS FUSE_FS             # [confirm] fuse-overlayfs only?

`display`, added 2026-09-20 because it would PASS today -- a capability check
added while everything agrees is one nobody has to defend, and `BOARD_FEATURES`
declares `display` on exactly the two boards whose kernels can render:

    display             VT VT_CONSOLE FRAMEBUFFER_CONSOLE FB \
                        (DRM_ROCKCHIP|AMLOGIC_DRM|DRM_I915|DRM_VIRTIO_GPU|FB_EFI)
    display-input       INPUT_KEYBOARD HID HID_GENERIC USB_HID

The parenthesised group is an ANY-OF: the display driver is board-specific by
nature and a fixed list would have to be edited for every new board, so the
row form needs one alternation. Splitting the input half out is deliberate --
a board can render without a keyboard path, and the two failures look nothing
alike to a person standing in front of it.

**And the limit of the whole mechanism, stated here rather than discovered
later: a capability row is a NECESSARY condition, not a proof of function.**
uefi-x64 is the worked example: it has `FB_EFI=y` and
`FRAMEBUFFER_CONSOLE=y`, so this row would pass, and yet
`DRM_FBDEV_EMULATION` is not set while `DRM_I915` is built in, and a DRM
driver taking over the device usually removes the EFI framebuffer. Whether a
VT survives that handover is a runtime fact no config expresses. A capability
check catches a board that CANNOT do a thing; only a bench or a guest proves
that it DOES.

**2. Each board's kernel component publishes what it provides.** The build
already has the resolved config in hand where the floor is asserted; it emits
`kernel/capabilities.tsv` there -- the capability names from the vocabulary
that the resolved config satisfies -- and `outputs.tsv` lists it like any
other component file. A consumer then reads capabilities from the component
it already pins, with no rebuild and no second source of truth.

**3. The comparison lives in mica-build, not here.** This repository cannot
know which products declare what, and a release run here builds one board.
`mica-build` joins `FEATURES` against the pinned board's
`kernel/capabilities.tsv` and refuses a product whose feature has no
capability behind it. That is the same shape as the pool check that catches a
duplicated package: the repository that sees both sides owns the refusal.

## The division of ownership this rests on

- **mica-podman** states what the engine and its helpers call -- it traced
  crun to the `memory.max` write, and the `[confirm]` rows are the same
  question asked four more times.
- **mica-build** owns the feature list and the join, and says which products
  declare what.
- **mica-boards** owns the vocabulary and the emission: turning "a memory
  limit must be enforceable" into `CONFIG_MEMCG`, and proving it against the
  resolved config of each board.

## What it would cost here

- one file (`common/kernel/capabilities.tsv`), one generator in the build
  where the floor is already asserted, one `outputs.tsv` row per board, one
  test;
- `common/kernel/` is in every board's kernel inputs, so all four kernels
  rebuild at the next release after it lands. Their bytes should not change:
  emitting a file into the component does not alter the kernel, and that is
  checkable by layer comparison at the first release;
- no symbol is turned on by this proposal. It makes a gap VISIBLE and
  refusable; closing a gap is a separate decision with its own cost, measured
  for the two known ones: `CONFIG_MEMCG` + `CONFIG_CFS_BANDWIDTH` on uefi-x64
  is +69632 bytes of bzImage (+0.46 %), five config lines, a changed
  `modules.tar`, and re-recorded configs for review. Boot-time cost is
  unmeasured and belongs on a bench.

## Open questions for the user

1. Should a product whose declared feature has no capability behind it be
   REFUSED, or published with the gap recorded? Refusal is the honest default
   and it would stop `uefi-x64-dev` today.
2. Are the two known gaps closed (turn the symbols on) or declared (the
   feature is not offered on that board)? The measurement above is the cost of
   the first; the second costs nothing and says so out loud.
3. `container-rootless` is drafted because it was asked about, not because it
   is wanted. mica-podman records rootless as unsupported today.
