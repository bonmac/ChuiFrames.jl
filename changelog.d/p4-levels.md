### Fixed
- A lazy join no longer shows unobserved dictionary levels: when a `group_by(...; drop = false)`
  (or a `drop = false` scan) is anywhere in the plan, a join's collected side (x when x is the
  build side, y always) reads the partitions a row limit stopped before or statistics pruned
  for their column kinds, as eager `read_source` does, so a key read from partitions with
  different dictionaries is decoded and `drop = false` adds no group with `n = 0` (CF-008;
  test/lazy/join_levels_tests.jl and a new join property). No row changes; plans without
  `drop = false` read as before.
- `explain` no longer says "no hash-aggregate sink: the stage's output schema is not known" for
  a grouped summary above a streamed join probe: `collect` collects the build side first and
  may then use the sink, so `explain` says the sink is decided at collect.

### Changed
- Docs: `docs/src/lazy.md` "Not yet" lists only what phase 4 did not add (sinks and compiled
  kernels are in); `docs/src/performance.md` says the lazy-join losses' causes (P4-02, P4-05)
  are fixed since b30cea3 and not re-timed yet. The `stage_kernel` docstring says which empty
  morsels run through the kernel.
