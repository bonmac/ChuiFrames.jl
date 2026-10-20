# tidyr nesting verbs (phase 2b): nest, unnest, unnest_longer, unnest_wider, pack, unpack.
# Behaviour follows tidyr 1.3.1 (checked with `Rscript`, see test/engine/differential_tidyr_nest_tests.jl).
# Nested tables are ChuiFrames `Frame`s in an object column (ADR-0001 rule 12); packed columns
# are struct columns (rule 6). Element types come from the declared column types where they are
# known (rule 1): a list column's child type, a struct column's field types.

# ---------------------------------------------------------------------------------------------
# Shared helpers

# `name => selector` specs from positional Pairs and keywords; reserved keywords are options
# (ADR-0002 rule 14: a column with a reserved name is written as a Pair, `"by" => [:x]`).
function _namedsels(verb::Symbol, args::Tuple, kw, reserved::Tuple)
    opts = Dict{Symbol, Any}()
    specs = Pair{Symbol, Any}[]
    for a in args
        (a isa Pair && a.first isa Union{Symbol, AbstractString}) ||
            throw(ArgumentError("$verb: a positional argument must be a \"name\" => columns Pair, got $(repr(a))"))
        push!(specs, Symbol(a.first) => a.second)
    end
    for (k, v) in pairs(kw)
        if k in reserved
            opts[k] = v
        else
            push!(specs, k => v)
        end
    end
    return specs, opts
end

_sepopt(x::Nothing) = nothing
_sepopt(x::Union{AbstractString, Symbol, AbstractChar}) = String(string(x))
_sepopt(x) = throw(ArgumentError("names_sep must be a string or nothing, got $(repr(x))"))

# The selected column names, refusing grouping columns (they are keys, never nested or packed).
function _selected(f::Frame, sel, verb)
    ns = Symbol[f.names[i] for i in resolve(sel, f)]
    for n in ns
        n in f.groups && throw(ArgumentError("$verb: cannot use the grouping column $(repr(n)); ungroup() first"))
    end
    return ns
end

# `prefix<sep>name` -> `name` (nest/pack with names_sep), and the reverse for unnest/unpack.
function _strip_prefix(n::Symbol, outer::Symbol, sep::String)
    p = string(outer, sep)
    s = string(n)
    return startswith(s, p) && ncodeunits(s) > ncodeunits(p) ? Symbol(s[(ncodeunits(p) + 1):end]) : n
end
_inner_name(outer::Symbol, inner, sep::Nothing) = Symbol(inner)
_inner_name(outer::Symbol, inner, sep::String) = Symbol(outer, sep, inner)

_fmtspecs(specs) = join([(Base.isidentifier(k) ? "$k = " : "$(repr(string(k))) => ") * _selrepr(v) for (k, v) in specs], ", ")
_fmtsep(sep) = sep === nothing ? "" : "names_sep = $(repr(sep))"

function _checkunique(names::Vector{Symbol}, verb)
    seen = Set{Symbol}()
    dup = Symbol[]
    for n in names
        n in seen ? push!(dup, n) : push!(seen, n)
    end
    isempty(dup) || throw(ArgumentError("$verb: the result would have duplicate column names $(join(repr.(unique(dup)), ", ")); give names_sep to disambiguate"))
    return names
end

_outframe(f::Frame, names::Vector{Symbol}, cols::Vector{AbstractColumn}, n::Int) =
    Frame(names, cols, Symbol[g for g in f.groups if g in names], nothing, n)

@inline _isnull(x) = x === missing || x === nothing

# The declared element type of the values inside a nested column's elements.
_innertype(::Type{V}) where {V <: AbstractVector} = eltype(V)
_innertype(::Type{NamedTuple{N, T}}) where {N, T <: Tuple} = Union{fieldtypes(T)...}
_innertype(::Type) = Any
_innertype_of(col) = (E = nonmissingtype(eltype(col)); E === Union{} ? Any : _innertype(E))

# Table elements of a column: Frames, NamedTuples of vectors, or other Tables.jl tables that
# are not vectors (a vector of values is unnested longer).
_istable_el(x::Frame) = true
_istable_el(x::NamedTuple) = !isempty(x) && all(v -> v isa AbstractVector, values(x))
_istable_el(x::Union{AbstractVector, AbstractString, Number, AbstractDict, Symbol, AbstractChar}) = false
_istable_el(x) = Tables.istable(x)

function _checknested(col, nm, verb)
    col isa Union{ListColumn, ObjectColumn} && return col
    # NamedTuples of vectors ingest as a struct column of list columns: those are tables
    col isa StructColumn && !isempty(col.children) && all(ch -> ch isa ListColumn, values(col.children)) && return col
    hint = col isa StructColumn ? "; it is a struct column: use unpack($(repr(nm)))" : ""
    throw(ArgumentError("$verb: column $(repr(nm)) (element type $(eltype(col))) is not a list column of tables or vectors$hint"))
end

# =============================================================================================
# nest

struct NestStep <: Step
    specs::Vector{Pair{Symbol, Any}}
    by::Any
    names_sep::Union{Nothing, String}
end

"""
    nest(name = sel, ...; by = nothing, names_sep = nothing)
    nest()                                  # on a grouped frame

Nest columns into a column of `Frame`s (an object column with element type `Frame`): one row
per distinct combination of the other columns (the keys), in order of first appearance, as
tidyr. `nest(data = [:x, :y])`, `nest(data = Not(:g))`; several specs make several nested
columns. Keys keep their order and come first; nested columns follow, in spec order.

- On a grouped frame, `nest()` nests the non-grouping columns into `data`; the result keeps
  the grouping (and tidyr's first-appearance row order, not the group order).
- `by = sel` nests every column except `sel` into `data`.
- `names_sep = "_"` strips `"<name>_"` from the nested columns' names.
- `missing` is a key value like any other (ADR-0003 rule 8 key equality).

`by` and `names_sep` are reserved; a nested column with such a name is written as a Pair,
`nest("by" => [:x])`.
"""
function nest(args...; kw...)
    specs, opts = _namedsels(:nest, args, kw, (:by, :names_sep))
    by = get(opts, :by, nothing)
    by !== nothing && !isempty(specs) &&
        throw(ArgumentError("nest: give the nested columns (nest(data = …)) or by = …, not both"))
    return NestStep(specs, by, _sepopt(get(opts, :names_sep, nothing)))
end
function Base.show(io::IO, s::NestStep)
    parts = String[]
    isempty(s.specs) || push!(parts, _fmtspecs(s.specs))
    opts = String[]
    s.by === nothing || push!(opts, "by = $(_selrepr(s.by))")
    s.names_sep === nothing || push!(opts, _fmtsep(s.names_sep))
    return print(io, "nest(", join(parts, ", "), isempty(opts) ? "" : "; " * join(opts, ", "), ")")
end

function apply(s::NestStep, f::Frame)
    specs = if !isempty(s.specs)
        Pair{Symbol, Vector{Symbol}}[nm => _selected(f, sel, "nest") for (nm, sel) in s.specs]
    elseif s.by !== nothing
        keep = Set(f.names[resolve(s.by, f)])
        Pair{Symbol, Vector{Symbol}}[:data => Symbol[n for n in f.names if !(n in keep) && !(n in f.groups)]]
    else
        Pair{Symbol, Vector{Symbol}}[:data => Symbol[n for n in f.names if !(n in f.groups)]]
    end
    allnested = Symbol[n for (_, ns) in specs for n in ns]
    allunique(allnested) || throw(ArgumentError("nest: a column is selected by more than one nested column: $(allnested)"))
    nested = Set(allnested)
    keys = Symbol[n for n in f.names if !(n in nested)]
    codes, firstrows = isempty(keys) ? (ones(Int, f.nrow), f.nrow == 0 ? Int[] : [1]) :
        rowcodes(AbstractVector[getcol(f, k) for k in keys])
    members = [Int[] for _ in firstrows]
    for (r, k) in enumerate(codes)
        push!(members[k], r)
    end
    names = copy(keys)
    cols = AbstractColumn[take(getcol(f, k), firstrows) for k in keys]
    for (nm, ns) in specs
        inner = s.names_sep === nothing ? copy(ns) : Symbol[_strip_prefix(n, nm, s.names_sep) for n in ns]
        sub = Frame(_checkunique(inner, "nest"), AbstractColumn[getcol(f, n) for n in ns], Symbol[], nothing, f.nrow)
        push!(names, nm)
        push!(cols, ObjectColumn(Frame[take(sub, m) for m in members]))
    end
    return _outframe(f, _checkunique(names, "nest"), cols, length(firstrows))
end

# =============================================================================================
# unnest

struct UnnestStep <: Step
    cols::Vector{Any}
    keep_empty::Bool
    names_sep::Union{Nothing, String}
end

"""
    unnest(cols...; keep_empty = false, names_sep = nothing)

Expand list columns row-wise. A column of tables (`Frame`s or any Tables.jl table) is replaced
by the tables' columns, spliced at its position (the union of their names in first-seen order;
a table missing a column gives `missing`). A column of vectors becomes one column of their
values. Other columns repeat. Several columns unnest in parallel: per row, sizes must agree, and
size 1 and `missing` elements recycle (tidyr: "can't recycle input of size a to size b").

- A row whose element is empty (an empty table or vector, or `missing`) is dropped, unless
  `keep_empty = true`, which keeps one row of `missing`.
- Values of different types across rows are combined with `vcat_columns` (lossless numeric
  promotion, else an object column).
- `names_sep = "_"` names spliced table columns `<col>_<name>`.
- With no rows, the other columns are kept with their types (prototype bug 6) and an unnested
  column of tables with no table to read names from is kept as an all-`missing` placeholder,
  as tidyr's unspecified column.
"""
unnest(cols...; keep_empty::Bool = false, names_sep = nothing) =
    isempty(cols) ? throw(ArgumentError("unnest: name the list columns to unnest, e.g. unnest(:data)")) :
    UnnestStep(Any[cols...], keep_empty, _sepopt(names_sep))
function Base.show(io::IO, s::UnnestStep)
    opts = String[]
    s.keep_empty && push!(opts, "keep_empty = true")
    s.names_sep === nothing || push!(opts, _fmtsep(s.names_sep))
    return print(io, "unnest(", join(_selrepr.(s.cols), ", "), isempty(opts) ? "" : "; " * join(opts, ", "), ")")
end

_elsize(x) = _istable_el(x) ? nrows(_asframe(x)) : x isa AbstractVector ? length(x) : 1

function apply(s::UnnestStep, f::Frame)
    sel = Symbol[f.names[i] for i in resolve(s.cols, f)]
    isempty(sel) && return f
    cols = AbstractColumn[_checknested(getcol(f, n), n, "unnest") for n in sel]
    # a column is a table column when any of its elements is a table
    istab = [any(x -> !_isnull(x) && _istable_el(x), c) for c in cols]
    for (j, c) in enumerate(cols), (i, x) in enumerate(c)
        _isnull(x) && continue
        _istable_el(x) == istab[j] ||
            throw(ArgumentError("unnest: column $(repr(sel[j])) mixes tables and other values (row $i holds a $(typeof(x)))"))
    end
    reps = Int[]
    chunks = [Tuple{Any, Int}[] for _ in cols]   # (element or nothing, output size) per kept row
    for i in 1:f.nrow
        els = Any[c[i] for c in cols]
        sizes = [_isnull(x) ? -1 : _elsize(x) for x in els]
        non1 = unique(sz for sz in sizes if sz >= 0 && sz != 1)
        length(non1) > 1 && throw(ArgumentError("unnest: in row $i, can't recycle input of size $(minimum(non1)) to size $(maximum(non1))"))
        target = isempty(non1) ? (any(>=(0), sizes) ? 1 : 0) : non1[1]
        if target == 0
            # empty tables still contribute their column names and types
            for j in eachindex(cols)
                istab[j] && !_isnull(els[j]) && push!(chunks[j], (els[j], 0))
            end
            s.keep_empty || continue
            target = 1
            els = Any[nothing for _ in els]
        end
        append!(reps, Base.fill(i, target))
        for j in eachindex(cols)
            push!(chunks[j], (_isnull(els[j]) ? nothing : els[j], target))
        end
    end
    n = length(reps)
    names = Symbol[]
    outcols = AbstractColumn[]
    for (k, nm) in enumerate(f.names)
        j = findfirst(==(nm), sel)
        if j === nothing
            push!(names, nm)
            push!(outcols, take(f.columns[k], reps))
        elseif istab[j]
            for (inm, c) in _unnest_tables(chunks[j], nm, s.names_sep, n)
                push!(names, inm)
                push!(outcols, c)
            end
        else
            T = _innertype_of(cols[j])
            push!(names, nm)
            push!(outcols, typed_column(_unnest_values(chunks[j], n), s.keep_empty ? Union{Missing, T} : T))
        end
    end
    return _outframe(f, _checkunique(names, "unnest"), outcols, n)
end

function _unnest_values(chunks, n)
    vals = Vector{Any}(undef, 0)
    sizehint!(vals, n)
    for (x, t) in chunks
        if x === nothing
            append!(vals, Base.fill(missing, t))
        elseif x isa AbstractVector
            length(x) == t ? append!(vals, x) : append!(vals, Base.fill(x[1], t))
        else
            append!(vals, Base.fill(x, t))
        end
    end
    return vals
end

function _unnest_tables(chunks, nm::Symbol, sep, n::Int)
    frames = Union{Nothing, Frame}[x === nothing ? nothing : _asframe(x) for (x, _) in chunks]
    inner = Symbol[]
    for fr in frames
        fr === nothing && continue
        for c in fr.names
            c in inner || push!(inner, c)
        end
    end
    isempty(inner) && n == 0 && return Pair{Symbol, AbstractColumn}[nm => column(Missing[])]
    out = Pair{Symbol, AbstractColumn}[]
    for c in inner
        parts = AbstractColumn[]
        for (fr, (_, t)) in zip(frames, chunks)
            if fr === nothing || !hascolumn(fr, c)
                push!(parts, column(Vector{Missing}(missing, t)))
            else
                col = getcol(fr, c)
                push!(parts, fr.nrow == t ? col : take(col, Base.fill(1, t)))
            end
        end
        push!(out, _inner_name(nm, c, sep) => _vcat_nonempty(parts))
    end
    return out
end

# =============================================================================================
# unnest_longer

struct UnnestLongerStep <: Step
    col::Any
    values_to::Union{Nothing, Symbol}
    indices_to::Union{Nothing, Symbol}
    keep_empty::Bool
end

"""
    unnest_longer(col; values_to = nothing, indices_to = nothing, keep_empty = false)

One row per element of each element of `col`: vectors (list columns), NamedTuples (struct
columns) and `AbstractDict`s with `Symbol` or string keys. The values go to `values_to`
(default: `col`'s name). Named elements (NamedTuples, Dicts) also give an index column of names,
`<col>_id` by default; `indices_to = :i` asks for one (positions for unnamed vectors). Empty or
`missing` elements drop their row unless `keep_empty = true` (one row of `missing`). A Dict's
entries come in its iteration order (use an ordered dict for a fixed order).
"""
function unnest_longer(col; values_to = nothing, indices_to = nothing, keep_empty::Bool = false)
    return UnnestLongerStep(col, values_to === nothing ? nothing : Symbol(values_to), indices_to === nothing ? nothing : Symbol(indices_to), keep_empty)
end
function Base.show(io::IO, s::UnnestLongerStep)
    opts = String[]
    s.values_to === nothing || push!(opts, "values_to = $(repr(s.values_to))")
    s.indices_to === nothing || push!(opts, "indices_to = $(repr(s.indices_to))")
    s.keep_empty && push!(opts, "keep_empty = true")
    return print(io, "unnest_longer(", _selrepr(s.col), isempty(opts) ? "" : "; " * join(opts, ", "), ")")
end

function _onecol(f::Frame, sel, verb)
    pos = resolve(sel, f)
    length(pos) == 1 || throw(ArgumentError("$verb: select exactly one column, got $(length(pos)) ($(join(repr.(f.names[pos]), ", ")))"))
    return f.names[pos[1]]
end

_dictkey(k::Union{Symbol, AbstractString}, verb) = String(string(k))
_dictkey(k, verb) = throw(ArgumentError("$verb: dictionary keys must be Symbols or strings, got a $(typeof(k))"))

# (values, names or nothing) of one element
_entries(x::NamedTuple, verb) = (Any[values(x)...], String[string(k) for k in keys(x)])
_entries(x::AbstractDict, verb) = (Any[v for v in values(x)], String[_dictkey(k, verb) for k in keys(x)])
_entries(x::AbstractVector, verb) = (Any[v for v in x], nothing)
_entries(x, verb) = (Any[x], nothing)

function apply(s::UnnestLongerStep, f::Frame)
    nm = _onecol(f, s.col, "unnest_longer")
    col = getcol(f, nm)
    col isa Union{ListColumn, ObjectColumn, StructColumn} ||
        throw(ArgumentError("unnest_longer: column $(repr(nm)) (element type $(eltype(col))) is not a list, struct or object column"))
    reps = Int[]
    vals = Any[]
    idx = Any[]
    named = false
    for i in 1:f.nrow
        x = col[i]
        v, ks = _isnull(x) ? (Any[], nothing) : _entries(x, "unnest_longer")
        ks === nothing || (named = true)
        if isempty(v)
            s.keep_empty || continue
            push!(reps, i)
            push!(vals, missing)
            push!(idx, missing)
            continue
        end
        append!(reps, Base.fill(i, length(v)))
        append!(vals, v)
        append!(idx, ks === nothing ? collect(1:length(v)) : ks)
    end
    vname = s.values_to === nothing ? nm : s.values_to
    iname = s.indices_to !== nothing ? s.indices_to : named ? Symbol(nm, "_id") : nothing
    T = _innertype_of(col)
    vcol = typed_column(vals, s.keep_empty ? Union{Missing, T} : T)
    icol = if iname === nothing
        nothing
    elseif named
        typed_column(Any[x isa Integer ? missing : x for x in idx], s.keep_empty ? Union{Missing, String} : String)
    else
        typed_column(idx, s.keep_empty ? Union{Missing, Int} : Int)
    end
    names = Symbol[]
    outcols = AbstractColumn[]
    for (k, n) in enumerate(f.names)
        if n === nm
            push!(names, vname)
            push!(outcols, vcol)
            if icol !== nothing
                push!(names, iname)
                push!(outcols, icol)
            end
        else
            push!(names, n)
            push!(outcols, take(f.columns[k], reps))
        end
    end
    return _outframe(f, _checkunique(names, "unnest_longer"), outcols, length(reps))
end

# =============================================================================================
# unnest_wider

struct UnnestWiderStep <: Step
    col::Any
    names_sep::Union{Nothing, String}
end

"""
    unnest_wider(col; names_sep = nothing)

One column per name of the elements of `col`: NamedTuples (struct columns too), `AbstractDict`s
with `Symbol` or string keys, or vectors. Names are the union over rows in first-seen order;
an absent name or a `missing` element gives `missing`. Unnamed vectors need `names_sep` (as
tidyr, which errors without it) and give `<col><sep>1`, `<col><sep>2`, …; `names_sep` also
prefixes named elements. The new columns replace `col`. A name equal to another column's is an
`ArgumentError`. With no rows (no names to read) the column is dropped, as tidyr.
"""
unnest_wider(col; names_sep = nothing) = UnnestWiderStep(col, _sepopt(names_sep))
Base.show(io::IO, s::UnnestWiderStep) = print(io, "unnest_wider(", _selrepr(s.col), s.names_sep === nothing ? "" : "; " * _fmtsep(s.names_sep), ")")

# A struct column's children, with a null parent nulling the child slot.
function _struct_children(c::StructColumn)
    v = validity(c)
    idx = v === nothing ? nothing : [v[i] ? i : 0 for i in 1:length(c)]
    return Pair{Symbol, AbstractColumn}[k => (idx === nothing ? ch : take(ch, idx)) for (k, ch) in pairs(c.children)]
end

function apply(s::UnnestWiderStep, f::Frame)
    nm = _onecol(f, s.col, "unnest_wider")
    col = getcol(f, nm)
    new = if col isa StructColumn
        Pair{Symbol, AbstractColumn}[_inner_name(nm, k, s.names_sep) => ch for (k, ch) in _struct_children(col)]
    else
        col isa Union{ListColumn, ObjectColumn} ||
            throw(ArgumentError("unnest_wider: column $(repr(nm)) (element type $(eltype(col))) is not a list, struct or object column"))
        _unnest_widen(col, nm, s.names_sep, f.nrow)
    end
    others = Set(n for n in f.names if n !== nm)
    clash = [k for (k, _) in new if k in others]
    isempty(clash) || throw(ArgumentError("unnest_wider: the new columns $(join(repr.(clash), ", ")) from $(repr(nm)) duplicate existing column names; give names_sep to disambiguate (names_sep = \"_\")"))
    names = Symbol[]
    outcols = AbstractColumn[]
    for (k, n) in enumerate(f.names)
        if n === nm
            for (a, b) in new
                push!(names, a)
                push!(outcols, b)
            end
        else
            push!(names, n)
            push!(outcols, f.columns[k])
        end
    end
    return Frame(_checkunique(names, "unnest_wider"), outcols, Symbol[g for g in f.groups if g in names], nothing, f.nrow)
end

function _unnest_widen(col, nm::Symbol, sep, n::Int)
    keys_ = String[]
    rows = Vector{Union{Nothing, Tuple{Vector{Any}, Vector{String}}}}(undef, n)
    for i in 1:n
        x = col[i]
        if _isnull(x)
            rows[i] = nothing
            continue
        end
        v, ks = _entries(x, "unnest_wider")
        if ks === nothing
            sep === nothing && throw(ArgumentError("unnest_wider: can't unnest elements with missing names (column $(repr(nm)), row $i); give names_sep to generate names, e.g. names_sep = \"_\""))
            ks = String[string(k) for k in 1:length(v)]
        end
        rows[i] = (v, ks)
        for k in ks
            k in keys_ || push!(keys_, k)
        end
    end
    T = _innertype_of(col)
    out = Pair{Symbol, AbstractColumn}[]
    for k in keys_
        vals = Vector{Any}(missing, n)
        for i in 1:n
            r = rows[i]
            r === nothing && continue
            p = findfirst(==(k), r[2])
            p === nothing || (vals[i] = r[1][p])
        end
        push!(out, _inner_name(nm, k, sep) => typed_column(vals, T))
    end
    return out
end

# =============================================================================================
# pack / unpack

struct PackStep <: Step
    specs::Vector{Pair{Symbol, Any}}
    names_sep::Union{Nothing, String}
end

"""
    pack(name = sel, ...; names_sep = nothing)

Pack the selected columns into a struct column (`NamedTuple` elements, ADR-0001 rule 6), one
per spec, appended after the remaining columns. `names_sep = "_"` strips `"<name>_"` from the
packed names. Grouping columns cannot be packed. `names_sep` is reserved.
"""
function pack(args...; kw...)
    specs, opts = _namedsels(:pack, args, kw, (:names_sep,))
    return PackStep(specs, _sepopt(get(opts, :names_sep, nothing)))
end
Base.show(io::IO, s::PackStep) = print(io, "pack(", _fmtspecs(s.specs), s.names_sep === nothing ? "" : "; " * _fmtsep(s.names_sep), ")")

function apply(s::PackStep, f::Frame)
    specs = Pair{Symbol, Vector{Symbol}}[nm => _selected(f, sel, "pack") for (nm, sel) in s.specs]
    packed = Set(n for (_, ns) in specs for n in ns)
    names = Symbol[n for n in f.names if !(n in packed)]
    cols = AbstractColumn[getcol(f, n) for n in names]
    for (nm, ns) in specs
        inner = s.names_sep === nothing ? copy(ns) : Symbol[_strip_prefix(n, nm, s.names_sep) for n in ns]
        _checkunique(inner, "pack")
        push!(names, nm)
        push!(cols, StructColumn(NamedTuple{Tuple(inner)}(Tuple(getcol(f, n) for n in ns)); length = f.nrow))
    end
    return Frame(_checkunique(names, "pack"), cols, copy(f.groups), nothing, f.nrow)
end

struct UnpackStep <: Step
    cols::Vector{Any}
    names_sep::Union{Nothing, String}
end

"""
    unpack(cols...; names_sep = nothing)

Replace each struct column by its fields, in place; a `missing` struct value gives `missing`
fields. `names_sep = "_"` names them `<col>_<field>`. A field name equal to another column's is
an `ArgumentError`.
"""
unpack(cols...; names_sep = nothing) = UnpackStep(Any[cols...], _sepopt(names_sep))
Base.show(io::IO, s::UnpackStep) = print(io, "unpack(", join(_selrepr.(s.cols), ", "), s.names_sep === nothing ? "" : "; " * _fmtsep(s.names_sep), ")")

function apply(s::UnpackStep, f::Frame)
    sel = Set(f.names[i] for i in resolve(s.cols, f))
    names = Symbol[]
    cols = AbstractColumn[]
    for (k, n) in enumerate(f.names)
        if n in sel
            c = f.columns[k]
            c isa StructColumn || throw(ArgumentError("unpack: column $(repr(n)) (element type $(eltype(c))) is not a struct column"))
            for (a, ch) in _struct_children(c)
                push!(names, _inner_name(n, a, s.names_sep))
                push!(cols, ch)
            end
        else
            push!(names, n)
            push!(cols, f.columns[k])
        end
    end
    return Frame(_checkunique(names, "unpack"), cols, Symbol[g for g in f.groups if g in names], nothing, f.nrow)
end
