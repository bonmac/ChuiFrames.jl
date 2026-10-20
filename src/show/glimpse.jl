# glimpse: the transposed view, one line per column (tibble/dplyr `glimpse`).
#
# R reference (tibble 3.3.0):
#   > glimpse(tibble(x = c(1.23456789, NA, -1e6), s = c("a", "a very long string that goes on and on", NA),
#   +                l = list(1:2, "a", NULL)))
#   Rows: 3
#   Columns: 3
#   $ x <dbl> 1.234568e+00, NA, -1.000000e+06
#   $ s <chr> "a", "a very long string that goes on and on", NA
#   $ l <list> <1, 2>, "a", <NULL>
# A grouped frame adds `Groups: g [n]` (dplyr's glimpse method). Values print as Julia shows
# them compactly (`1.23457`, `-1.0e6`, `"a"`, `[1, 2]`, `missing`); a line longer than the
# display width ends in `…`.

_glimpse_text(::Missing) = "missing"
_glimpse_text(x::AbstractString) = string('"', escape_string(x), '"')
_glimpse_text(x::Union{Date, DateTime}) = string(x)
_glimpse_text(x::ByteView) = cell_text(x)
_glimpse_text(x::AbstractVector) = sprint(show, collect(x); context = (:compact => true, :limit => true, :typeinfo => typeof(collect(x))))
_glimpse_text(x) = sprint(show, x; context = (:compact => true, :limit => true))

"""
    glimpse([io::IO = stdout,] f)

Print a transposed view of a frame (or any Tables.jl table): its dimensions, then one line per
column with the column's name, its type label (as under printed headers) and as many leading
values as fit the display width. Returns `nothing`.
"""
glimpse(f) = glimpse(stdout, f)
glimpse(io::IO, t) = glimpse(io, Frame(t))
function glimpse(io::IO, f::Frame)
    width = displaysize(io)[2]
    names = getfield(f, :names)
    cols = getfield(f, :columns)
    nr = getfield(f, :nrow)
    println(io, "Rows: ", _bigmark(nr))
    print(io, "Columns: ", _bigmark(length(names)))
    groups = getfield(f, :groups)
    if !isempty(groups)
        print(io, "\nGroups: ", join(header_text.(groups), ", "), " [", _bigmark(_ngroups(f)), "]")
    end
    isempty(names) && return nothing
    heads = header_text.(names)
    types = type_sum.(cols)
    wh = maximum(textwidth, heads)
    wt = maximum(textwidth, types)
    for j in eachindex(names)
        line = IOBuffer()
        print(line, "\$ ", pad_right(heads[j], wh), " ", pad_right(types[j], wt))
        used = 2 + wh + 1 + wt
        for i in 1:nr
            s = _glimpse_text(cols[j][i])
            print(line, i == 1 ? " " : ", ", s)
            used += textwidth(s) + (i == 1 ? 1 : 2)
            used > width && break
        end
        print(io, '\n', truncate_text(rstrip(String(take!(line))), width))
    end
    return nothing
end
