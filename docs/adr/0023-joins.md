# ADR-0023: Joins follow dplyr 1.2.0 through one hash-join operator in three physical shapes, chosen by the cost stage; keys are `by =`, and integer/float key pairs compare as `Float64`

- **Status:** Proposed (2026-10-26)
- **Date:** 2026-10-26
- **Deciders:** the user (★ K1–K4 and the `nest_join` name-clash ruling, 2026-10-26, at the
  ChuiFrames phase-4 ★); acceptance of this record: the ecosystem lead or the user
- **Scope:** ChuiFrames.jl

## Context

Phase 4 adds joins (DESIGN §7 item 1). The design is spec
`docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md` §0.4 and §1; this
ADR records it as built on `feat/phase4` at 50dbf18 (joins merged in 0db65f4). It **refines and
implements** ADR-0003 rules 4 (the cost stage picks the build side and strategy), 8 (key
equality), 10 (one radix primitive) and 11 (broadcast, else both sides radix-partitioned).
Under ★ K2 ADR-0003 is kept as written: this ADR amends none of its rules. ADR-0002 rule 16
carries the dated ★ K1 amendment (`by` replaces `on`); `join_by` extends its key forms (★ K3).
dplyr facts: `Rscript`, dplyr 1.2.0 (spec §1.6). Code: src/engine/{join,join_shapes,verbs_join}.jl,
src/lazy/joins.jl.

## Decision

**Verbs and keys**
1. Verbs: `inner_join`, `left_join`, `right_join`, `full_join` (no `unmatched`), `semi_join`,
   `anti_join`, `nest_join`, `cross_join`, `join_by` (★ K3), each a `JoinStep`. Keys **must** be
   `by =`: `nothing` (natural join, one `@info` when names resolve), `:a`, `"a"`, `[:a, :b]`,
   `:a => :b`, vectors of those, or `join_by(...)`.
2. `join_by` **must** accept equality pairs only; a node (`c.a .== c.b`) is an `ArgumentError`
   pointing to `:a => :b`. Inequality and rolling joins are deferred: no design exists.
3. The DataAPI methods `innerjoin`, `leftjoin`, `rightjoin`, `outerjoin`, `semijoin` and
   `antijoin` on `(x::Frame, y)` **must** keep DataAPI's keyword `on` and forward it to `by`,
   other keywords unchanged (ADR-0007); `crossjoin(x, y)` forwards to `cross_join`. The seven
   names sit in the ExplicitImports `INTERFACE` of `test/package_tests.jl` (non-public in DataAPI).
4. `nest_join`'s column is an `ObjectColumn` of `Frame`s (tidyr `nest`'s representation). A
   `name` equal to an x column **must** replace it at its position, as dplyr does, and log one
   `@warn` when names resolve, never in replay (user ruling). A `name` equal to x's key under
   `keep = false` replaces the key; no key predicate is pushed through it.
5. **Key pairs (★ K4).** `_keypair_compare_type(Sx, Sy)` (src/engine/hashagg.jl) gives, in order:
   a `Union{}` side → the other type; identical → that type; two string types → `String`; a
   lossless numeric pair → `promote_type`; any other integer or `Bool` with an IEEE float →
   `Float64`; else `nothing` → `ArgumentError` naming both columns (`Date`/`DateTime`,
   `Int64`/`UInt64`, string/number). Numeric keys **must** be converted to it before
   `typed_keys`/`keyhash`. Above 2⁵³ two integer keys can round to one `Float64` and match the
   same row: documented, remedy "convert the key first". Abstract key types → `ArgumentError`.
6. Output keys under `keep = false` have the compare type; `keep = true` and semi/anti keep each
   side's keys unconverted. Element types widen by join kind, never from the data.

**Execution**
7. `join_decision(spec, x::SideEstimate, y::SideEstimate)` is the cost stage for eager apply,
   the lowering at `collect` and `explain`. Build side: fewer estimated bytes (rows × nominal
   width); a tie or both unknown → y; one unknown side counts as larger. Broadcast **must** be
   used below `BROADCAST_MAX_ROWS = 131_072` rows and `BROADCAST_MAX_BYTES = 4 MiB`; otherwise
   both sides go through `radix_partition` into 2ᵖ partitions, `p = clamp(⌈log2 rows⌉ − 13, 4, 8)`
   of the larger side (4 when unknown). `collect` confirms the strategy on the collected build side.
8. **Three shapes.** (a) broadcast, build y: `ProbeStep` streams x; pairs come out in (xrow,
   yrow) order, so the order-restoring sort **must** be skipped. (b) broadcast, build x: y
   streams; a `JoinTailStep` numbers y rows (`cumsum(##chui_ystart)`) and sorts. (c)
   partitioned: `PartitionedJoinStep` in `rest`, both sides gathered. (b) and (c) **must**
   restore dplyr's order with a stable counting sort by x row, O(m + |x|).
9. Hidden columns use the reserved prefix `##chui_`; a user column or `nest_join` `name` with it
   is an `ArgumentError`. Tails are breakers placed by `isstreamable`; `execute.jl` has no join code.
10. **Errors.** One ascending pass over x, before `multiple`, raises for the first x row failing
    an x-side check: no match under `unmatched = :error` (inner, right) or several matches under
    `multiple = :error`. Then the y-side check (inner, left, nest). Eager **must** raise the same
    exception under every shape; partition probes raise nothing. Lazy raises the same type, and
    `collect`'s eager replay (ADR-0003 rule 7 note) gives eager's message.
11. **Pushdown.** A join is total when `unmatched = :drop` and `multiple ≠ :error`; a filter
    **must not** move past a non-total join, nor to y unless `multiple = :all`. One-side filters
    move: inner either side, left x, right y, full never, semi/anti x (no type condition: x is
    unconverted), nest x (never on the nested column), cross either. A key predicate moves to x
    only for inner/left/nest, with both key types static and the compare type equal to x's key
    type; it is never copied to y. A limit stops early past a join only in shape (a) with no
    tail (`_steptotal`).
12. **Static key types.** Key types are static only when `node_schema` proves them; the
    empty-frame probe is trusted for names only. Otherwise the lowering **must** collect that
    side before choosing a shape and run the K4 checks on the collected types.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Always build on y | Contradicts ADR-0003 rule 4, kept by the user (★ K2); a 10³-row x against 10⁷-row y would build 10⁷ entries. |
| Partition only the build side, stream the probe | Contradicts rule 11 as written (★ K2); needs hashing inside x's stage (deferred, spec §6). |
| Keep `on =` | dplyr parity (★ K1); DataAPI keeps `on`. |
| Reject integer/float key pairs (critic pass 2 N1) | dplyr compares them as double (★ K4); the 2⁵³ loss is documented. |
| Error on, or rename, a `nest_join` `name` clash | dplyr replaces silently; the user chose dplyr's result plus a `@warn`. |
| Ship `join_by(c.a .== c.b)` now | Fixes a side convention before the inequality/rolling design; adds nothing over `:a => :b`. |
| Key types from the empty-frame probe | Critic pass 3 MAJOR-1: after a `mutate` it is not the data's type; lazy would raise where eager succeeds. |

## Consequences

- Every shape returns the same frame (CF-008): (xrow, yrow) order, `multiple` per x row, only
  chosen y rows matched, one error precedence, static element types.
- Any upstream `mutate`, even off the key, makes a side non-static, so shape (a) then collects it.
- Divergences (docs/research/differentials-joins.md, parity-dplyr.md): suffix `("_x", "_y")`;
  `nest_join` default `name` `:y`; no `multiple = "warning"` or many-to-many warning; Polars and
  DuckDB match NaN with NaN under `:never`, ChuiFrames follows dplyr (encoded in the test).
- **As-built deviation:** eager broadcast joins probe the whole frame on the calling task at any
  size (spec §1.2 says below 65 536 rows); eager partitioned joins spawn tasks from 65 536 rows.
- **Open follow-ups:** an x key held as `ObjectColumn{SubString}` keeps that kind on
  inner/left/nest instead of `String` (reviewer p4-join pass 2; lazy == eager); parallel eager
  broadcast probes (p4-bench); partition bits p and nominal widths untuned (p4-bench); static
  types per key column.

## Verification

- Main checkout `.lanes/reports/` (gitignored): `reviewer-p4-join-pass1.md` (pre-K4, at
  0d00cda: 20 dplyr cases, every `_FORCE_JOIN` value, morsels 1–7, `-t 4`, 0 differences),
  `reviewer-p4-join-pass2.md` (APPROVE FINAL at 8e63b5e: K4 probed under every shape),
  `critic-p4.md`, `critic-p4-pass2.md`, `critic-p4-pass3.md`.
- Gates: `.lanes/reports/lanes/p4-join/evidence/` files `tests-8e63b5e.txt`,
  `tests-t4-8e63b5e.txt`, `tests-lts-8e63b5e.txt`, `tests-diff-8e63b5e.txt`,
  `tests-slow-t4-8e63b5e.txt`. Differentials: evidence `tests-diff-b13e506.txt`.
- UNVERIFIED: DataFusion's limits as input bytes; the nominal 16-byte width (p4-bench).

## Revisit when

- p4-bench measures the order-restoring sort above 25 % of a shape-(b)/(c) join, or a
  small-x/large-y join more than 2× slower than DuckDB → reconsider shapes (b)/(c).
- A join behind an upstream non-key `mutate` is more than 1.5× slower than without → static
  types per key column.
- A user reports the 2⁵³ loss as a problem → an opt-in strict mode rejecting lossy pairs.
- The inequality/rolling `join_by` design starts → reopen rule 2.
