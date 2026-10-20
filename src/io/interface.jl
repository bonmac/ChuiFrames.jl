# The Source and Sink interface (ADR-0004 rules 2, 7, 8 and 10; chui-frames.md CF-011 to CF-015).
# The names are public API written qualified (`ChuiFrames.Source`, ...): they are not exported.

"""
    ChuiFrames.Source

Supertype of every data source (ADR-0004 rule 2, CF-011). A new source is a subtype in its
author's own package with four required methods:

- [`source_schema(s)`](@ref source_schema)`::Tables.Schema`: column names and element types;
- [`source_label(s)`](@ref source_label)`::String`: the label `explain` shows;
- [`plan_partitions(s, scan::Tables.Scan; morsel)`](@ref plan_partitions)`::Tuple{Vector,Tables.Scan}`:
  the partition handles, in partition order, and the **residual** `Scan` (CF-012);
- [`read_partition(s, p)`](@ref read_partition): a Tables.jl table for handle `p`.

The optional methods have defaults: [`partition_stats`](@ref), [`row_count`](@ref),
[`partition_row_count`](@ref), [`source_ordering`](@ref), [`source_groups`](@ref),
[`isthreadsafe`](@ref) (`false`: reads are serialized behind one lock) and
[`source_boundedness`](@ref) (`:bounded`).
"""
abstract type Source end

"""
    source_schema(s::Source) -> Tables.Schema

The column names and declared element types of `s` (required, ADR-0004 rule 2).
"""
function source_schema end

"""
    source_label(s::Source) -> String

A short label for `s`, shown by `explain` (required).
"""
function source_label end

"""
    plan_partitions(s::Source, scan::Tables.Scan; morsel::Int) -> (handles::Vector, residual::Tables.Scan)

Plan the partitions of `s` for the pushdown request `scan` (required, ADR-0004 rules 1-3,
CF-012). Each handle carries everything [`read_partition`](@ref) needs (the pushed projection,
filter and per-partition limit). The residual follows `Tables.Scan`'s axis rules: a source that
applies nothing returns `scan` itself, which is always correct. The columns a handle returns must
include every column the residual references. `morsel` is the engine's target partition size in
rows; a source may ignore it.
"""
function plan_partitions end

"""
    read_partition(s::Source, p) -> Tables.jl table

Read the partition for handle `p`, applying what the handle pushed down (required).
"""
function read_partition end

"""
    partition_stats(s::Source, p, col::Symbol) -> Union{Nothing, NamedTuple}

Statistics of column `col` in partition `p`: `nothing`, or `(; lo, hi, nnull, nnan, ndistinct)`
with every field present and each possibly `nothing` (ADR-0004 rule 4, CF-013). `lo`/`hi` are
bounds, not exact values; a source reports `nothing` for a bound it does not know, and never a
NaN bound.
"""
partition_stats(::Source, p, col) = nothing

"""
    row_count(s::Source) -> Union{Nothing, Tuple{Int,Bool}}

`(n, exact)` when the source knows its row count (exactly or as an upper bound), else `nothing`.
"""
row_count(::Source) = nothing

"""
    partition_row_count(s::Source, p) -> Union{Nothing, Tuple{Int,Bool}}

`(n, exact)` for partition `p` when known, else `nothing`.
"""
partition_row_count(::Source, p) = nothing

"""
    source_ordering(s::Source)

The source's declared sort order (ADR-0004 rule 6; its declaration is PROVISIONAL), or
`nothing` (the default).
"""
source_ordering(::Source) = nothing

"""
    source_groups(s::Source) -> Vector{Symbol}

Columns the source is pre-grouped by (default: none).
"""
source_groups(::Source) = Symbol[]

"""
    isthreadsafe(s::Source) -> Bool

`true` when `read_partition` may run concurrently on `s`. The default is `false` (fail-closed,
ADR-0004 rule 10): reads are serialized behind one lock.
"""
isthreadsafe(::Source) = false

"""
    source_boundedness(s::Source) -> Symbol

`:bounded` (the default and, in v0, the only value; ADR-0004 rule 8, CF-015). Reserved for a
streaming variant, which will add a new method instead of changing `plan_partitions`.
"""
source_boundedness(::Source) = :bounded

"""
    ChuiFrames.Sink

Supertype of every data sink (ADR-0004 rule 7, CF-014). Sinks are transactional:

- [`open_sink(k, schema::Tables.Schema)`](@ref open_sink) returns a state;
- [`write_partition!(state, part)`](@ref write_partition!) takes one Tables.jl table, in
  partition order, and **must** convert it to the declared schema or raise an `ArgumentError`;
- [`close_sink!(state)`](@ref close_sink!) flushes, writes footer and metadata, and commits;
- [`abort_sink!(state, err)`](@ref abort_sink!) discards. It is called on **any** exception
  after `open_sink`, and then `close_sink!` is not.

Built-in file sinks write to a temporary path in the target's directory and rename it in
`close_sink!`; `abort_sink!` deletes the temporary file.
"""
abstract type Sink end

"""
    open_sink(k::Sink, schema::Tables.Schema) -> state

Start a write of data with the declared `schema`.
"""
function open_sink end

"""
    write_partition!(state, part)

Write one partition (a Tables.jl table), converted to the declared schema; raise an
`ArgumentError` if it cannot be converted.
"""
function write_partition! end

"""
    close_sink!(state)

Flush and commit the write.
"""
function close_sink! end

"""
    abort_sink!(state, err)

Discard the write (delete its temporary file). Never throws for a built-in sink.
"""
function abort_sink! end
