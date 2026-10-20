# Sources, sinks and file formats (sub-lane `p2-io`): the Source/Sink interface and the format
# registry (ADR-0004), the Arrow IPC writer adapter over Arrow.jl (ADR-0010, ADR-0001 rule 11)
# and the source over the own reader, and CSV over CSV.jl 1.x (ADR-0019). Parquet is the
# Parquet2 package extension (ADR-0020, ext/ChuiFramesParquet2Ext.jl).

using Arrow: Arrow
using CSV: CSV

include("interface.jl")
include("conform.jl")
include("execute.jl")
include("tables_source.jl")
include("registry.jl")
include("arrow.jl")
include("csv.jl")

# The Source/Sink names are written qualified (`ChuiFrames.Source`, ...; chui-frames.md
# CF-011 to CF-016) and are not exported, nor is `scan_file` (its result type is PROVISIONAL
# until the lazy entry points land). The everyday reading/writing names are.
export read_file, write_file, read_csv, read_tsv, write_csv, write_tsv, read_arrow, write_arrow

"Register the built-in formats (called from `ChuiFrames.__init__`)."
function _init_formats()
    _register_builtin!(:arrow; source = ArrowSource, sink = ArrowSink, extensions = [".arrow", ".feather", ".ipc", ".arrows"])
    _register_builtin!(:csv; source = scan_csv, sink = CSVSink, extensions = [".csv", ".tsv", ".tab"])
    return nothing
end
