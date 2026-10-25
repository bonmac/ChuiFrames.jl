# The hash-aggregate and grouped-window sinks (phase-4 spec §2.1, §2.3). Group-by lane.

"`explain`'s lines for what runs after the streamed stage (seam version: the phase-3 text)."
function _explain_rest(io::IO, ph)
    println(io, "  then materialize (concatenate in morsel order)")
    return isempty(ph.rest) || println(io, "  then eagerly: ", join(string.(ph.rest), " ⨟ "))
end
