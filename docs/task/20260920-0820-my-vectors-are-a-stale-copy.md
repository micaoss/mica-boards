# 20260920-0820-my-vectors-are-a-stale-copy Which mica commit this repository's lock vectors came from

- **status**: done
- **priority**: P2
- **owner**: tdpnmgkr
- **createdAt**: 2026-09-20 08:20

The coordinator asked every repository three questions about its lock reader.
The third is the one a count cannot answer: **is the copy a deliberate subset
or a stale one?** Measured rather than remembered.

## The answer: stale, and datable to the commit

`tests/vectors/expected.tsv` holds **64 non-comment rows** against mica's
canonical **84** (2026-09-20). Comparing my set against every canonical
snapshot in `mica`'s history:

    canonical af717a6  2026-09-15  63 rows   differs from mine by ONE file
    canonical a0ec066  2026-09-15  69 rows   differs by seven
    canonical f742615  2026-09-16  78 rows
    canonical 258f93a  2026-09-20  84 rows

**My set is canonical at `af717a6` plus exactly one file**:
`lock/refused/release-slash.lock`, which I added by hand on 2026-09-16 during
the dot cut-over. 63 + 1 = 64.

So it is not a subset anyone chose. It is 2026-09-15's copy with one vector
added for the change I happened to be making -- and that partial refresh is
what made it look tended. The suite stayed green throughout, because the
fixtures and the reader agree with each other.

## The defect the count did not show

Canonical carries `lock/valid/mica-boards.uefi-x64.lock`; I carried
`lock/valid/mica-boards.x64.lock`. **My own valid-lock fixture named the board
name the rename retired on 2026-09-16** -- in the one place where no copy can
be blamed, since this repository owns that board. Replaced with the canonical
file, and `tests/locks-test.sh`'s scope-refusal case points at it.

## What this repository actually needs, derivable rather than argued

The spec's new rule is that a reader must pass every vector for the forms it
CAN ENCOUNTER, and what it can encounter follows from what it pins:

    pinned:   locks/mica-build-env.lock   release, image        (one producer, unscoped)
              locks/upstream.lock         git, source           (third-party, this repo's own)
    produced: mica-boards.lock            release (SCOPED), pool, package, board

So the forms are `release` unscoped and scoped, `image`, `git`, `source`,
`pool`, `package`, `board`, and the pin file. **`data`, `index`, `update`,
`bundle` and `asset` are forms this repository never meets**: it pins no
mica-system-base lock, reads no index, and consumes no product release. The
20 vectors I lack are almost exactly those families -- which is why the size
looked defensible and was not the question.

## And what the reader does with a kind it does not know

Measured: **refuses, loudly.** A row of an unknown kind and a `data` row both
produce `refused kind-unknown` and exit 1. So if a producer this repository
pins ever adds a row kind, the build stops rather than pinning something it
half-read. That is the right failure and it is why the missing `data` vectors
are a gap in CONFORMANCE COVERAGE rather than a live hazard here.

## Provenance now travels with the copy

`tests/vectors/expected.tsv` carries a header naming the mica commit it was
taken from, the one file added by hand, and the families it deliberately does
not carry. Until the ruled mechanism lands -- read the vectors out of mica at
a pinned commit and refuse a difference -- that header is what makes "stale"
answerable by anyone reading the file, which was the point of the rule.
