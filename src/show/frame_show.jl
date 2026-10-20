# tibble-style printing of a Frame: header, group line, column headers, type row, rows, footers.
#
# R reference (tibble 3.3.0, `options(width = 60)`):
#   > print(group_by(tibble(g = c("a","b","a"), h = c(1,1,2), x = 1:3), g, h))
#   # A tibble: 3 × 3
#   # Groups:   g, h [3]
#     g         h     x
#     <chr> <dbl> <int>
#   1 a         1     1
#   ...
#   > print(as_tibble(setNames(as.list(1:100), paste0("column_", 1:100)))[rep(1, 30), ])
#   # A tibble: 30 × 100
#      column_1 column_2 column_3 column_4 column_5 column_6
#         <int>    <int>    <int>    <int>    <int>    <int>
#    1        1        2        3        4        5        6
#   ... (10 rows)
#   # ℹ 20 more rows
#   # ℹ 94 more variables: column_7 <int>, column_8 <int>,
#   #   column_9 <int>, column_10 <int>, column_11 <int>,
#   ... (7 footer lines at most, the last ending in `, …`)
#   > tibble(x = integer(0))            # A tibble: 0 × 1 / # ℹ 1 variable: x <int>
#   > tibble(.rows = 3)                 # A tibble: 3 × 0
#   > tibble(x = 1:12345)               # A tibble: 12,345 × 1 ... # ℹ 12,335 more rows
#   > tibble(s = c("", " a", "b"))      # cells "" / " a" / "b": quoted when any needs it
#
# Layout rules (tibble/pillar, adapted):
# - more than 20 rows: show 10; otherwise all (`:limit => false` shows every row and column);
# - the output also fits `displaysize(io)`: at most `height - 1` lines, `width` columns;
# - columns are taken left to right at their minimum width (numbers never shrink; text shrinks
#   to 15 characters with `…`), then the spare width widens them in order up to their ideal;
# - numbers and their headers are right-aligned, everything else left-aligned;
# - `missing` replaces R's `NA` / `<NA>` (dimmed when the io has `:color`); headers that are
#   not identifiers print as `var"my col"` (tibble backquotes them; ADR-0002 rule 18);
# - trailing spaces are dropped from every line.

const MAX_ROWS = 20          # more rows than this: show ROWS_SHOWN (tibble's print_max / print_min)
const ROWS_SHOWN = 10
const MIN_CHR_WIDTH = 15     # pillar.min_chr_width
const MAX_FOOTER_LINES = 7   # lines of the "more variables" footer

struct _Pillar
    header::String
    type::String
    cells::Vector{String}
    missings::BitVector
    right::Bool              # right-aligned and never shrunk (numbers)
end

_isnumcol(T) = (T <: Integer || T <: AbstractFloat) && !(T <: Bool)

function _needs_quotes(s::AbstractString)
    isempty(s) && return true
    return isspace(first(s)) || isspace(last(s))
end

function _pillar(name::Symbol, col::AbstractColumn, rows)
    vals = [col[i] for i in rows]
    miss = BitVector(ismissing(x) for x in vals)
    T = nonmissingtype(eltype(col))
    if _isnumcol(T)
        cells = num_cells(vals)
        right = true
    else
        quoted = T <: AbstractString && any(x -> !ismissing(x) && _needs_quotes(x), vals)
        cells = String[
            ismissing(x) ? "missing" : quoted ? string('"', escape_string(x), '"') : cell_text(x)
                for x in vals
        ]
        right = false
    end
    return _Pillar(header_text(name), type_sum(col), cells, miss, right)
end

_cellwidth(p::_Pillar) = isempty(p.cells) ? 0 : maximum(textwidth, p.cells)
_ideal(p::_Pillar) = max(textwidth(p.header), textwidth(p.type), _cellwidth(p))
_minwidth(p::_Pillar) = p.right ? _ideal(p) :
    max(textwidth(p.header), textwidth(p.type), min(_cellwidth(p), MIN_CHR_WIDTH))

"""
    fit_widths(ideal, minw, avail) -> Vector{Int}

Widths of the leading columns that fit in `avail` characters (one separating space before each
column): as many columns as fit at their minimum widths, then the spare width given to them in
order, each up to its ideal width (pillar's layout).
"""
function fit_widths(ideal::AbstractVector{<:Integer}, minw::AbstractVector{<:Integer}, avail::Integer)
    k = 0
    used = 0
    for m in minw
        used + 1 + m > avail && break
        used += 1 + m
        k += 1
    end
    w = Int[minw[i] for i in 1:k]
    extra = avail - used
    for i in 1:k
        add = min(extra, ideal[i] - w[i])
        w[i] += add
        extra -= add
    end
    return w
end

_dim(s, color::Bool) = color ? string("\e[90m", s, "\e[39m") : s

"`_bigmark(n)`: `n` with thousands separated by commas, as tibble's dimension descriptions."
function _bigmark(n::Integer)
    s = string(abs(n))
    parts = String[]
    while length(s) > 3
        pushfirst!(parts, s[(end - 2):end])
        s = s[1:(end - 3)]
    end
    pushfirst!(parts, s)
    return string(n < 0 ? "-" : "", join(parts, ","))
end

_plural(n, word) = n == 1 ? word : word * "s"

function _ngroups(f::Frame)
    gi = getfield(f, :gindex)
    gi === nothing || return ngroups(gi)
    keys = [getcol(f, g) for g in getfield(f, :groups)]
    return length(unique(ntuple(k -> keys[k][r], length(keys)) for r in 1:getfield(f, :nrow)))
end

# "# ℹ <lead><tok>, <tok>, …" wrapped to `width`, continuation lines starting with "#   ".
function _footer_lines(lead::AbstractString, toks::Vector{String}, width::Integer, maxlines::Integer)
    lines = String[]
    cur = string("# ℹ ", lead)
    fresh = true
    for (i, t) in enumerate(toks)
        piece = i < length(toks) ? t * "," : t
        if !fresh && textwidth(cur) + 1 + textwidth(piece) > width
            push!(lines, cur)
            if length(lines) == maxlines
                lines[end] = string(lines[end], " …")
                return lines
            end
            cur = string("#   ", piece)
        else
            cur = fresh ? string(cur, piece) : string(cur, " ", piece)
        end
        fresh = false
    end
    push!(lines, cur)
    return lines
end

_var_tokens(f::Frame, idx) = String[string(header_text(getfield(f, :names)[j]), " ", type_sum(getfield(f, :columns)[j])) for j in idx]

# The lines of the printed frame (without colour codes except where `color`).
function _frame_lines(f::Frame, width::Integer, height::Integer, limit::Bool, color::Bool)
    names = getfield(f, :names)
    cols = getfield(f, :columns)
    nr = getfield(f, :nrow)
    nc = length(names)
    head = String[_dim(string("# A Frame: ", _bigmark(nr), " × ", _bigmark(nc)), color)]
    if !isempty(getfield(f, :groups))
        g = join(header_text.(getfield(f, :groups)), ", ")
        push!(head, _dim(string("# Groups:  ", g, " [", _bigmark(_ngroups(f)), "]"), color))
    end
    nc == 0 && return head
    if nr == 0
        lead = string(_bigmark(nc), " ", _plural(nc, "variable"), ": ")
        foot = _footer_lines(lead, _var_tokens(f, 1:nc), limit ? width : typemax(Int), limit ? MAX_FOOTER_LINES : typemax(Int))
        return vcat(head, _dim.(foot, color))
    end
    nshow = limit && nr > MAX_ROWS ? ROWS_SHOWN : nr
    budget = limit ? max(height - 1, 1) : typemax(Int)
    local body, foot
    for _ in 1:4                         # shrink the rows until the output fits the height
        body, foot = _body(f, nshow, width, limit, color)
        total = length(head) + length(body) + length(foot)
        (total <= budget || nshow == 1) && break
        nshow = max(nshow - (total - budget) - (nshow == nr ? 1 : 0), 1)
    end
    return vcat(head, body, foot)
end

function _body(f::Frame, nshow::Int, width::Integer, limit::Bool, color::Bool)
    names = getfield(f, :names)
    cols = getfield(f, :columns)
    nr = getfield(f, :nrow)
    nc = length(names)
    rw = ndigits(nshow)
    # Only pillars that could fit are built (each takes at least two characters).
    ncand = limit ? min(nc, max(width ÷ 2, 1)) : nc
    pillars = [_pillar(names[j], cols[j], 1:nshow) for j in 1:ncand]
    ideal = _ideal.(pillars)
    widths = limit ? fit_widths(ideal, _minwidth.(pillars), width - rw) : ideal
    k = length(widths)
    lines = String[]
    if k > 0
        hdr = IOBuffer()
        typ = IOBuffer()
        print(hdr, " "^rw)
        print(typ, " "^rw)
        for j in 1:k
            p, w = pillars[j], widths[j]
            h = truncate_text(p.header, w)
            print(hdr, " ", p.right ? pad_left(h, w) : pad_right(h, w))
            pad = " "^(w - textwidth(p.type))
            print(typ, " ", p.right ? pad : "", _dim(p.type, color), p.right ? "" : pad)
        end
        push!(lines, rstrip(String(take!(hdr))), rstrip(String(take!(typ))))
        for i in 1:nshow
            row = IOBuffer()
            print(row, _dim(pad_left(string(i), rw), color))
            for j in 1:k
                p, w = pillars[j], widths[j]
                c = p.right ? pad_left(p.cells[i], w) : pad_right(truncate_text(p.cells[i], w), w)
                color && p.missings[i] && (c = replace(c, "missing" => _dim("missing", true)))
                print(row, " ", c)
            end
            push!(lines, rstrip(String(take!(row))))
        end
    end
    foot = String[]
    if nshow < nr
        push!(foot, string("# ℹ ", _bigmark(nr - nshow), " more ", _plural(nr - nshow, "row")))
    end
    if k < nc
        lead = string(_bigmark(nc - k), " more ", _plural(nc - k, "variable"), ": ")
        append!(foot, _footer_lines(lead, _var_tokens(f, (k + 1):nc), width, MAX_FOOTER_LINES))
    end
    return lines, _dim.(foot, color)
end

function Base.show(io::IO, ::MIME"text/plain", f::Frame)
    h, w = displaysize(io)
    lines = _frame_lines(f, w, h, get(io, :limit, false)::Bool, get(io, :color, false)::Bool)
    join(io, lines, '\n')
    return nothing
end

function Base.show(io::IO, f::Frame)
    names = join(header_text.(getfield(f, :names)), ", ")
    print(io, "Frame: ", _bigmark(getfield(f, :nrow)), " × ", _bigmark(length(getfield(f, :names))), " [", truncate_text(names, 50), "]")
    groups = getfield(f, :groups)
    isempty(groups) || print(io, ", grouped by ", join(header_text.(groups), ", "))
    return nothing
end
