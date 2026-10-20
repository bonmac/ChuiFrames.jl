"""
    ChuiFrames

Data frames for the Chui ecosystem: Arrow-layout columnar storage, dplyr/tidyr-style verbs
written with the macro-free `c.x` grammar, tibble-style printing, and Arrow IPC/CSV I/O
(Parquet through the Parquet2 extension).

Phase 2 (eager frame). See `docs/agent/BRIEF.md`, `docs/adr/` and `HANDOFF.md`.
"""
module ChuiFrames

using Dates: Dates, Date, DateTime
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

function __init__()
    _init_formats()
    _init_banner()
    return nothing
end

end # module ChuiFrames
