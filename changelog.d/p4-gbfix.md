- Fixed (CF-008): a lazy `head(n)` that stops the scan early no longer keeps the first
  partitions' dictionary when a later step shows dictionary levels (`group_by(...; drop = false)`).
  The partitions the limit never reached are read for their column kinds only (their empty
  slice through the stage), as eager `read_source` reads every partition. Rows, the limit's rows
  and early stop for queries without such a step are unchanged (p4-groupby2 review follow-up).
- Fixed (codegen, p4-join review m5): a streamed stage with a step or node off the kernel
  whitelist (spec §3.2) is decided as the interpreter before any shape key or hash is computed,
  and writes nothing to the session kernel cache.
- Fixed (codegen review n1): the small-input shape hash includes a non-frame source's type and
  declared schema, so a verdict cached for one source no longer shows as "compiled (cached)" for
  another source with other column types; a stage whose program fails to build marks its
  decision and small-path verdicts rejected, as a declined morsel does.
- Tests: the hash-aggregate sink, the grouped-window sink and a focused grouped lazy == eager
  property run behind a forced compiled stage kernel, asserting that compiled programs ran and
  that `_KERNEL_DISAGREE` did not move.
