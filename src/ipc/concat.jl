# Kind-preserving gather, concatenation and empty columns for the reader.
#
# `take`/`vcat_columns` in columns.jl serve verbs; the reader needs operations that keep the
# exact column kind and offset width that the schema declares (a LargeUtf8 stays Int64, a
# dictionary column stays dictionary-encoded), so that every batch and the concatenation
# have the declared element types.

_gv(::Nothing, rows) = nothing
_gv(v::BitVector, rows) = v[rows]

"Rows `rows` (valid 1-based indices) of `c`, with the same column kind and offset type."
_gather(c::PrimitiveColumn, rows) = PrimitiveColumn(c.values[rows], _gv(c.validity, rows))
_gather(c::BoolColumn, rows) = BoolColumn(c.values[rows], _gv(c.validity, rows))
_gather(c::DictColumn, rows) = DictColumn(c.codes[rows], c.dict, _gv(c.validity, rows))
function _gather(c::C, rows) where {C <: VarColumn}
    O = eltype(c.offsets)
    total = sum((Int(c.offsets[i + 1] - c.offsets[i]) for i in rows); init = 0)
    O2 = total > typemax(O) ? Int64 : O
    offs = Vector{O2}(undef, length(rows) + 1)
    offs[1] = 0
    data = Vector{UInt8}(undef, total)
    pos = 0
    for (k, i) in enumerate(rows)
        a, len = Int(c.offsets[i]), Int(c.offsets[i + 1] - c.offsets[i])
        len > 0 && copyto!(data, pos + 1, c.data, a + 1, len)
        pos += len
        offs[k + 1] = pos
    end
    return (C <: StringColumn ? StringColumn : BinaryColumn)(offs, data, _gv(c.validity, rows))
end
function _gather(c::ListColumn, rows)
    O = eltype(c.offsets)
    offs = Vector{O}(undef, length(rows) + 1)
    offs[1] = 0
    crow = Int[]
    for (k, i) in enumerate(rows)
        append!(crow, (Int(c.offsets[i]) + 1):Int(c.offsets[i + 1]))
        offs[k + 1] = length(crow)
    end
    return ListColumn(offs, _gather(c.child, crow), _gv(c.validity, rows))
end
_gather(c::StructColumn, rows) =
    StructColumn(map(ch -> _gather(ch, rows), c.children), _gv(c.validity, rows); length = length(rows))

_cv(cols) = cols[1].validity === nothing ? nothing : reduce(vcat, BitVector[c.validity for c in cols])

"Concatenate same-kind columns in order (the batches of one schema field)."
function _concat(cols::Vector{AbstractColumn})
    length(cols) == 1 && return cols[1]
    return _concat(cols[1], cols)
end
_concat(::PrimitiveColumn, cols) = PrimitiveColumn(reduce(vcat, [c.values for c in cols]), _cv(cols))
_concat(::BoolColumn, cols) = BoolColumn(reduce(vcat, BitVector[c.values for c in cols]), _cv(cols))
function _concat(::C, cols) where {C <: VarColumn}
    total = sum(c -> length(c.data), cols)
    O = eltype(cols[1].offsets)
    O2 = total > typemax(Int32) ? Int64 : O
    offs = Vector{O2}(undef, sum(length, cols) + 1)
    offs[1] = 0
    data = Vector{UInt8}(undef, total)
    k, pos = 1, 0
    for c in cols
        n = length(c)
        base = Int(c.offsets[1])
        for i in 1:n
            offs[k + i] = pos + Int(c.offsets[i + 1]) - base
        end
        len = Int(c.offsets[end]) - base
        len > 0 && copyto!(data, pos + 1, c.data, base + 1, len)
        pos += len
        k += n
    end
    return (C <: StringColumn ? StringColumn : BinaryColumn)(offs, data, _cv(cols))
end
function _concat(::ListColumn, cols)
    total = sum(c -> Int(c.offsets[end]), cols)
    O = eltype(cols[1].offsets)
    O2 = total > typemax(Int32) ? Int64 : O
    offs = Vector{O2}(undef, sum(length, cols) + 1)
    offs[1] = 0
    k, base = 1, 0
    for c in cols
        for i in 1:length(c)
            offs[k + i] = base + Int(c.offsets[i + 1])
        end
        base += Int(c.offsets[end])
        k += length(c)
    end
    # list children are compacted on read (offsets start at 0 and end at the child's length)
    kids = AbstractColumn[length(c.child) == Int(c.offsets[end]) ? c.child : _gather(c.child, 1:Int(c.offsets[end])) for c in cols]
    return ListColumn(offs, _concat(kids), _cv(cols))
end
function _concat(c1::StructColumn, cols)
    names = keys(c1.children)
    kids = map(nm -> _concat(AbstractColumn[getfield(c.children, nm) for c in cols]), names)
    return StructColumn(NamedTuple{names}(Tuple(kids)), _cv(cols); length = sum(length, cols))
end

"""
Concatenate dictionary columns into one column over one unified dictionary (ADR-0003
rule 8): entries in order of first appearance across the batches, codes remapped.
"""
function _concat(c1::DictColumn, cols)
    d1 = c1.dict
    if all(c -> c.dict === d1, cols)
        C = mapreduce(c -> eltype(c.codes), promote_type, cols)
        return DictColumn(reduce(vcat, Vector{C}[Vector{C}(c.codes) for c in cols]), d1, _cv(cols))
    end
    seen = Dict{nonmissingtype(eltype(d1)), Int}()
    parts = AbstractColumn[]
    maps = Vector{Vector{Int}}()
    for c in cols
        m = Vector{Int}(undef, length(c.dict))
        newrows = Int[]
        for j in eachindex(c.dict)
            x = c.dict[j]
            code = get(seen, x, 0)
            if code == 0
                push!(newrows, j)
                code = length(seen) + 1
                seen[x] = code
            end
            m[j] = code
        end
        isempty(newrows) || push!(parts, _gather(c.dict, newrows))
        push!(maps, m)
    end
    dict = isempty(parts) ? d1 : _concat(parts)
    C = promote_type(mapreduce(c -> eltype(c.codes), promote_type, cols), _codetype(UInt8, length(dict)))
    codes = Vector{C}(undef, sum(length, cols))
    k = 0
    for (c, m) in zip(cols, maps)
        for x in c.codes
            codes[k += 1] = x == 0 ? C(0) : C(m[x])
        end
    end
    return DictColumn(codes, dict, _cv(cols))
end

"A zero-row column of the field's declared kind and element type."
function _empty(f::IPCField)
    v = f.nullable ? BitVector() : nothing
    if f.dict !== nothing
        vals = _strip(_empty(_valuefield(f)))
        return DictColumn(_codetype(f.dict.index)[], vals, v)
    end
    k = f.kind
    k === :prim && return PrimitiveColumn(f.T[], v)
    k === :bool && return BoolColumn(BitVector(), v)
    k in (:utf8, :binary, :utf8view, :binaryview) && return _varcol(f)(f.T[0], UInt8[], v)
    k === :list && return ListColumn(f.T[0], _empty(f.children[1]), v)
    names = Tuple(Symbol(ch.name) for ch in f.children)
    return StructColumn(NamedTuple{names}(Tuple(_empty(ch) for ch in f.children)), v; length = 0)
end
