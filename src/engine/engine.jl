# Engine entry point (sub-lane `p2-engine`): the upstream adapter (ADR-0014), the expression
# grammar (ADR-0002), the single-threaded interpreter with grouped-window evaluation and the
# eager verbs (ADR-0003 rules 1-3, 7, 8).

using DataAPI: Cols, Between, All
using InvertedIndices: InvertedIndices, Not
using Statistics: Statistics

include("upstream.jl")
include("aggregators.jl")
include("nodes.jl")
include("selectors.jl")
include("helpers.jl")
include("groups.jl")
include("radix.jl")
include("hashagg.jl")
include("interpreter.jl")
include("steps.jl")
include("verbs.jl")
include("verbs_groups.jl")
include("verbs_rows.jl")
include("verbs_bind.jl")
# joins (phase 4)
include("join.jl")
include("verbs_join.jl")
# tidyr reshaping (phase 2b)
include("verbs_pivot.jl")
include("verbs_strings.jl")
include("verbs_nest.jl")
include("verbs_complete.jl")

# The grammar (CF-002, CF-010) and its helpers (ADR-0002 rules 7-10).
export c, desc, across, each, if_any, if_all, where, everything, last_col, any_of, group_cols,
    n_rows, row_number, lag, lead, cummean, case_when, between, na_if, min_rank, dense_rank,
    consecutive_id, lit, n_distinct, nth, percent_rank, cume_dist, ntile, when_any, when_all,
    typed
# Selectors re-exported as the same bindings (ADR-0002 rule 7; never ChuiFrames' own).
export Cols, Between, All, Not
# Verbs (dplyr names; Base-named verbs such as `filter` are methods of the Base function).
export filter_out, select, rename, rename_with, relocate, mutate, pull, arrange, group_by,
    ungroup, summarise, summarize, reframe, head, slice_head, slice_tail, slice, slice_min,
    slice_max, slice_sample, distinct, count_by, tally, add_count, add_tally, bind_rows,
    bind_cols, union_rows, intersect_rows, setdiff_rows, symdiff_rows, union_all
# tidyr verbs (`fill` is a method of `Base.fill` on nodes, CF-009).
export pivot_longer, pivot_wider, separate_wider_delim, separate_wider_position,
    separate_wider_regex, separate_longer_delim, separate_longer_position, unite, nest, unnest,
    unnest_longer, unnest_wider, pack, unpack, complete, expand, nesting
