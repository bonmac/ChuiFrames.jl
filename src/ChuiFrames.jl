"""
    ChuiFrames

Data frames for the Chui ecosystem: Arrow-layout columnar storage, dplyr/tidyr-style verbs
written with the macro-free `c.x` grammar, tibble-style printing, and Arrow IPC/CSV I/O
(Parquet through the Parquet2 extension).

Phase 2 (eager frame). See `docs/agent/BRIEF.md`, `docs/adr/` and `HANDOFF.md`.
"""
module ChuiFrames

using Dates: Dates, Date, DateTime
using PrecompileTools: @compile_workload, @setup_workload
using Statistics: mean
using DataAPI: DataAPI
using StringViews: StringView
using Tables: Tables

# Storage and the frame (ADR-0001, ADR-0003 rule 3).
include("columns.jl")
include("frame.jl")

# The upstream adapter, the expression grammar, the interpreter and the eager verbs
# (ADR-0002, ADR-0003, ADR-0014).
include("engine/engine.jl")

# Arrow IPC: ChuiFrames' own reader (ADR-0001 rule 10).
include("ipc/ipc.jl")

# Sources and sinks, the format registry, the Arrow writer adapter and CSV (ADR-0004,
# ADR-0010, ADR-0019).
include("io/io.jl")

# tibble-style printing and the name-conflict banner stand-in.
include("show/show.jl")

export Frame, groupcols, isgrouped

# The Source/Sink interface and the format registry (chui-frames.md CF-011 to CF-016) are
# public but not exported: the contract writes them qualified (`ChuiFrames.Source`). `public` is
# a ParseError on Julia 1.10, hence the version gate.
@static if VERSION >= v"1.11"
    eval(
        Meta.parse(
            "public Source, Sink, TablesSource, source_schema, source_label, plan_partitions, " *
                "read_partition, partition_stats, row_count, partition_row_count, source_ordering, " *
                "source_groups, isthreadsafe, source_boundedness, open_sink, write_partition!, " *
                "close_sink!, abort_sink!, register_format!, scan_file"
        )
    )
end

# TTFX workload (ADR-0011; ADR-0010 rule 4: one small Arrow write). It covers the common first
# calls: building a frame, one pipeline of the core verbs, printing, and an Arrow and CSV round
# trip in a temporary directory.
@setup_workload begin
    nt = (g = ["a", "b", "a", missing], x = [1.5, 2.0, NaN, 4.0], n = [1, 2, 3, 4])
    @compile_workload begin
        _init_formats()
        f = Frame(nt)
        r = f |> filter(c.n .> 1) |> mutate(y = c.x .* 2) |> group_by(:g) |>
            summarise(m = mean(c.y), k = n_rows()) |> arrange(desc(c.m))
        show(IOContext(devnull, :displaysize => (24, 80), :limit => true), MIME("text/plain"), r)
        dir = mktempdir()
        try
            write_arrow(f, joinpath(dir, "w.arrow"))
            read_arrow(joinpath(dir, "w.arrow"))
            write_csv(f, joinpath(dir, "w.csv"))
            read_csv(joinpath(dir, "w.csv"))
        finally
            rm(dir; recursive = true, force = true)
        end
    end
end

function __init__()
    _init_formats()
    _init_banner()
    return nothing
end

end # module ChuiFrames
