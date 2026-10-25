# The hash-aggregate and grouped-window sinks (phase-4 spec §2.1, §2.3). Group-by lane.

"""
    run_rest(ph::Physical, out::Frame; morsel, threads) -> Frame

Run the steps after the streamed stage (`ph.rest`) on the gathered frame `out`. Seam version:
each step through its eager operator, as phase 3 (the group-by lane adds the sinks here).
"""
function run_rest(ph, out; morsel::Int = DEFAULT_MORSEL, threads::Bool = true)
    for s in ph.rest
        out = apply(s, out)
    end
    return out
end

"`explain`'s lines for what runs after the streamed stage (seam version: the phase-3 text)."
function _explain_rest(io::IO, ph)
    println(io, "  then materialize (concatenate in morsel order)")
    return isempty(ph.rest) || println(io, "  then eagerly: ", join(string.(ph.rest), " ⨟ "))
end
