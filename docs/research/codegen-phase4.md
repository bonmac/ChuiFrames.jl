# Research: compiled stage kernels and `INTERP_THRESHOLD` (phase 4)

**Question.** How much does a compiled stage kernel (phase-4 spec
[§3](../superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md), ADR-0003 rule 12)
cost to compile for a new shape, how much faster than the interpreter does it run per row, and
from how many estimated rows should `kernel_decision` compile a shape it has not compiled yet
(`INTERP_THRESHOLD`)? ADR-0003 rule 12 started the threshold at 10⁵ from the phase-1 probes
(EN-07, EN-08: 3–9 ms per two-operation shape against the prototype interpreter) and asked
phase 4 to recalibrate it.

- **Date:** 2026-10-26.
- **Versions:** Julia 1.13.2 and 1.10.12 (LTS), one thread (`-t 1`). ChuiFrames at the lane
  commit `fe71780` (branch `feat/p4-codegen`).
- **Hardware:** Apple M3 Pro, 12 cores (`hw.ncpu`), macOS (Darwin 25.6.0). Julia 1.10 reports
  the CPU as `apple-m1` with 6 CPU threads (its LLVM's name and count); it is the same machine.
- **Load caveat:** the machine was shared with other lanes while these numbers were taken; the
  1-minute load average was 2.6–3.3 during the runs (printed at the start and end of each
  evidence file). Each per-row number is the minimum of 7 runs, and each compile number is the
  median of 5 new shapes, so ratios are more reliable than absolute times. Three runs of the
  same per-shape code (commits `aa12a66`, `b279f87`, `fe71780`, evidence files of those names)
  gave compile medians within about 10% of each other on 1.13 (`steps 10`: 39.7, 40.7,
  43.4 ms; `depth 1`: 49.2, 48.7, 49.0 ms).
- **Evidence** (`julia scripts/evidence.jl <kind> -- <cmd>`, in the lane worktree):
  - `.lanes/evidence/codegen-measure-fe71780.txt` (Julia 1.13.2, `dirty: false`);
  - `.lanes/evidence/codegen-measure-lts-fe71780.txt` (Julia 1.10.12, `dirty: false`);
  - `.lanes/evidence/codegen-first-fe71780.txt` and `.lanes/evidence/codegen-first-lts-fe71780.txt`
    (the first kernel of a fresh session).

## Method

The measurement script is scratch code (not in the repo); it is reproduced at the end of this
note. It forces compilation (`_FORCE_KERNEL[] = :compiled`) and runs:

1. **Compile time per new shape.** For a stage that has not been compiled in the session:
   `stage_kernel(ph, 0)` (the decision, which builds the program once to check it) plus the
   first call on a 16-row frame (build, the `typeof(col)` probe check against the interpreter,
   JIT of the row loop), minus a steady call. The interpreter has run the same stage just
   before, so Base's broadcast methods for its functions are already compiled: that cost is
   paid on either path (median 0.18 ms, max 49 ms on 1.13 and 73 ms on 1.10, over 85 shapes),
   so it is not counted against the kernel. Two families, 5 random shapes each (shapes seen
   before are skipped):
   - one `mutate` of a chain of `d` binary operations (`+ - * max min` over three Float64
     columns and a literal), `d` = 1, 2, 5, 10, 20, 35, 50;
   - stages of `s` = 1–10 steps: each step is a filter on an Int column (keeping 7/9 to 9/9 of
     the rows, probability 0.3) or a `mutate` of a two-operation expression.
2. **Per-row time**, interpreter (`interpret_stage(ph)`) against compiled, on one morsel of
   65,536 rows (the default morsel) and of 10⁶ rows: stages of 1–10 steps (as above), a
   multi-column mutate, a string filter (`startswith`), a string filter plus a mutate, a
   `case_when`, and the depth-20 and depth-50 chains. Both results are checked equal first.
   The frame has three Float64 columns, an Int column and a String column; filtered stages
   `take` every column, including the String one.
3. **Break-even rows** = compile time ÷ per-row saving (65,536-row morsels), per stage kind.

## Results

Compile time per new shape (ms, median of 5; min–max in the evidence files):

| Shape | 1.13.2 | 1.10.12 |
|---|---|---|
| 1 operation | 49.0 | 17.4 |
| 2 operations | 24.6 | 21.5 |
| 5 operations | 32.9 | 24.3 |
| 10 operations | 47.7 | 32.8 |
| 20 operations | 73.9 | 63.9 |
| 35 operations | 131.4 | 107.9 |
| 50 operations | 227.0 | 174.8 |
| 1–10 steps | 22.7–43.4 | 17.7–32.2 |

Per-row time on a 65,536-row morsel (ns/row) and break-even rows:

| Stage | interp 1.13 | compiled 1.13 | break-even 1.13 | interp 1.10 | compiled 1.10 | break-even 1.10 |
|---|---|---|---|---|---|---|
| 1 step | 20.7 | 1.5 | 1,182,479 | 18.5 | 1.4 | 1,035,853 |
| 2 steps | 42.6 | 0.8 | 564,299 | 38.7 | 13.7 | 709,510 |
| 3 steps | 68.7 | 15.7 | 476,064 | 64.2 | 14.8 | 576,865 |
| 4 steps | 91.5 | 15.4 | 570,303 | 79.8 | 19.2 | 344,513 |
| 5 steps | 113.0 | 15.7 | 280,324 | 96.8 | 18.2 | 294,484 |
| 6 steps | 140.8 | 21.7 | 272,314 | 111.0 | 17.1 | 240,788 |
| 7 steps | 161.8 | 24.6 | 244,911 | 144.8 | 23.8 | 266,095 |
| 8 steps | 190.8 | 22.1 | 221,055 | 166.0 | 18.7 | 166,109 |
| 9 steps | 209.4 | 21.4 | 188,257 | 184.7 | 20.9 | 189,441 |
| 10 steps | 228.3 | 22.9 | 211,500 | 208.9 | 32.7 | 161,281 |
| multi-column | 42.0 | 0.9 | 574,218 | 36.0 | 1.0 | 505,592 |
| string filter | 33.6 | 13.0 | 1,147,815 | 33.2 | 16.2 | 1,043,078 |
| string filter + mutate | 49.4 | 17.2 | 732,971 | 42.6 | 17.8 | 715,021 |
| `case_when` | 122.0 | 1.6 | 195,986 | 98.5 | 1.6 | 183,132 |
| 20-operation chain | 26.2 | 1.0 | 2,926,148 | 23.3 | 1.0 | 2,874,609 |
| 50-operation chain | 35.7 | 3.4 | 7,014,506 | 31.7 | 3.4 | 6,179,805 |

The 10⁶-row morsels give the same picture (in the evidence files). Observations:

- The compiled row loop itself is 0.5–3.4 ns/row (no per-row allocation; `@test_opt` in
  `test/jet/opt_kernels.jl`). A stage with a filter costs 13–33 ns/row more, which is the
  `take` of every passed-through column (13 ns/row for the String column alone): the kernel
  keeps the interpreter's column objects (critic N3), so it pays the interpreter's `take`.
- The speed-up is 2.0–2.9× for string stages (the `take` dominates), 4–10× for multi-step
  stages, and 40–75× for single-pass numeric mutates and `case_when`.
- The interpreter costs about 20 ns/row per step; the per-row saving grows about linearly with
  the step count while the compile time grows slowly, so long stages break even sooner.

### What the compile time is

The first version of the kernel (commit `20b3347`) cost 240–280 ms per new shape on 1.13 in a
development run of the same script that was not kept as an evidence file. Three causes, fixed
in the lane (commits `aa12a66`, `b279f87`):

- Shape keys were tuples holding each node's function, so every shape was a new tuple type and
  compiled new `hash`/`isequal`/`Dict` methods. Keys are now `String`s.
- The builder collected heterogeneous blocks with `Tuple(generator)`, compiling array-widening
  code per new block type. It now collects into `Vector{Any}` and uses unspecialised
  constructors; `StageProgram` is not parametric, and one function barrier (`_kernelrun`) is
  the only method compiled per shape besides the blocks' own constructors.
- On Julia 1.10, `map` with a closure over the row context left nested kernel calls dynamic
  (1,782–5,803 ns/row at depths 20 and 50, slower than the interpreter;
  `.lanes/evidence/codegen-measure-lts-aa12a66.txt`); explicit tuple evaluation keeps them
  concrete (1.0 and 3.4 ns/row).

What remains per new shape is the JIT of `_kernelrun` and the row loop for the shape's types
(about 15–20 ms for a two-operation stage, from one `--trace-compile-timing` development run,
not kept) plus the blocks' constructors (1–3 ms each).

### The first kernel of a session

The kernel machinery itself (decision, builder, probe check, guarded run, output assembly) is
compiled the first time any kernel runs. Without a precompile workload that cost 813 ms on
1.13 and 613 ms on 1.10 (lane commit `b279f87`, `.lanes/evidence/codegen-first-b279f87.txt`
and `.lanes/evidence/codegen-first-lts-b279f87.txt`). A `@compile_workload` that runs one
compiled kernel at precompile time (end of `src/lazy/render.jl`, because it needs the physical
plan) brings the first kernel on a different shape to 168 ms on 1.13 and 77 ms on 1.10, and a
second new shape to 22.7 ms and 16.9 ms (`codegen-first-fe71780.txt`, `codegen-first-lts-fe71780.txt`).

## Decision: `INTERP_THRESHOLD = 500_000`

- The median break-even over the 16 stage kinds is about 5.2×10⁵ rows on 1.13 and 4.3×10⁵ on
  1.10; for the 1–10-step stages it ranges from 1.6×10⁵ to 1.2×10⁶. 5×10⁵ is where a new shape
  pays for itself in a single run for most stages with three or more steps, multi-column
  mutates and `case_when`.
- At 5×10⁵ rows the stages that break even later (one step, string filters) lose at most about
  15 ms once: their compile time is 18–25 ms and their saving at 5×10⁵ rows is 8–10 ms. The
  shape is then in the session cache, and every later run of it (at any row count) uses the
  compiled kernel.
- Deep chains (20–50 operations) break even only at 3–7×10⁶ rows. They are rare in practice;
  stages above 50 operations already run the interpreter (`MAX_KERNEL_NODES`, which now counts
  operations: Call and `case_when` nodes, not columns and literals).
- 10⁵ (the phase-1 value) would lose on almost every new shape here: the phase-1 probes
  measured 3–9 ms per shape for a bare closure, while the full kernel (probe check, column
  assembly, the exact-semantics checks of critic B2) costs 18–45 ms.
- Revisit when: the per-shape compile time drops (a cheaper probe check, or a smaller
  closure), the interpreter gets faster per step, or p4-bench's compiled-stage benchmark row
  disagrees with this table by more than 2×.

## Limits found (not in the threshold)

These shapes run the interpreter by design; the measurements above use none of them:

- A computed column whose type the interpreter narrows from the data: `/` and `sqrt` on Int
  columns (static type `Int`, values `Float64`; `typed_column` converts integral values back to
  `Int`). The kernel checks each value's type and declines the morsel (no disagreement
  counted); that column-type set then runs the interpreter for the session.
- A computed column of strings (a `String` value comes back as a `StrView` when read from its
  column), a nullable or non-concrete `select` pair, `case_when` values other than columns and
  scalar literals (a computed value's run-time element type can differ from its static one),
  and every node outside the whitelist (spec §3.2).

<details>
<summary>The measurement script (scratch, run as <code>julia [+lts] --project=. measure.jl</code>)</summary>

```julia
using ChuiFrames, Tables, Random, Printf
const CF = ChuiFrames
const ⨟ = CF.Upstream.:⨟
CF._FORCE_KERNEL[] = :compiled
const OPS = (+, -, *, max, min)
mkframe(n; seed = 1) = (rng = MersenneTwister(seed);
    Frame((x = randn(rng, n), y = randn(rng, n), w = randn(rng, n), i = rand(rng, 1:9, n), s = rand(rng, ["a", "bb", "ccc", "ab"], n))))
function chain(d, rng)                      # d binary operations
    e = c.x
    for _ in 1:d
        e = OPS[rand(rng, 1:length(OPS))].(e, rand(rng, (c.y, c.w, lit(1.5))))
    end
    return e
end
ph_of(st, f) = CF.physical(st(lazy(f)).plan)
const SMALL = mkframe(16)
# (a warm-up kernel on a shape not used below)
function compile_cost(st)                   # interpreter first (paid on either path), then the kernel
    ph = ph_of(st, SMALL)
    CF.interpret_stage(ph)(SMALL)
    t1 = @elapsed CF.stage_kernel(ph, 0)(SMALL)
    t2 = minimum(@elapsed(CF.stage_kernel(ph, 0)(SMALL)) for _ in 1:5)
    return t1 - t2
end
function stage_of(s, rng)                   # filters (p = 0.3) and 2-operation mutates
    steps = Any[]
    for j in 1:s
        if rand(rng) < 0.3
            push!(steps, filter(c.i .> rand(rng, 0:2)))
        else
            op1, op2 = OPS[rand(rng, 1:5)], OPS[rand(rng, 1:5)]
            push!(steps, mutate(; Symbol(:m, j) => op2.(op1.(c.x, c.y), c.w)))
        end
    end
    return foldl(⨟, steps)
end
function perrow(st, f; reps = 7)            # ns/row, minimum of reps
    ph = ph_of(st, f)
    k, ki = CF.stage_kernel(ph, 0), CF.interpret_stage(ph)
    k(f); ki(f)
    GC.gc()
    ti = minimum(@elapsed(ki(f)) for _ in 1:reps)
    tc = minimum(@elapsed(k(f)) for _ in 1:reps)
    return 1.0e9 * ti / f.nrow, 1.0e9 * tc / f.nrow
end
# compile_cost over 5 unseen shapes per depth (chain) and per step count (stage_of, seed 42);
# perrow on mkframe(65_536; seed = 7) and mkframe(1_000_000; seed = 7) for stage_of(1:10, seed 99)
# and the named stages; break-even = median compile / (interp - compiled).
```

</details>
