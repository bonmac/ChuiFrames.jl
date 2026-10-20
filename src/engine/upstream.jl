# The upstream adapter (ADR-0014): stand-ins for the pieces ChuiCore owns and has not released,
# named and shaped as ChuiCore's accepted ADRs (ADR-0001 aggregators as instance values, ADR-0003
# transducers, ADR-0005 `⨟`/`opcompose`). Every other ChuiFrames file reaches these names only
# qualified, through this module (`Upstream.combine`, ...). Nothing here is exported (ADR-0014
# rule 2). At ChuiCore's release each stand-in becomes a `const` re-binding (rule 3); the release
# gate fails while any body is still local (rule 5).
#
# Not here yet (phase 3, requested from ChuiCore): recursion schemes (`cata`, `ana`, a
# paramorphism) for the optimizer, and `foldxt`/`foldparts` for parallel folds.
module Upstream

# ---------------------------------------------------------------------------------------------
# `⨟` / `opcompose` (CC-001): left-to-right composition. ChuiFrames adds methods for its steps.

"""
    ⨟(f, g)

Left-to-right composition stand-in (CC-001): `(f ⨟ g)(x...) == g(f(x...))`. Internal until
ChuiCore releases its binding (ADR-0014 rule 2).
"""
function ⨟ end
⨟(f, g) = g ∘ f
const opcompose = ⨟

# ---------------------------------------------------------------------------------------------
# Aggregators (CC-004 to CC-007). Accumulators here are immutable values, so `init` is trivially a
# fresh factory and `partial`/`combine` never alias.

"Supertype of the stand-in aggregators."
abstract type Aggregator end

"The \"no value yet\" accumulator of semigroups and `Moments` (CC-006)."
struct NoValue end
const novalue = NoValue()

function init end
function partial end
function combine end
"`final(agg, acc)`: the user-visible result; the generic fallback is `acc` (CC-004)."
final(::Aggregator, acc) = acc
"`iscommutative(agg)`: generic default `false` (CC-005)."
iscommutative(::Any) = false
"`neutral(agg)`: a fresh identity accumulator for monoids; `ArgumentError` for semigroups."
neutral(agg) = throw(ArgumentError("$(agg) has no neutral element"))

# Fold a chunk with a binary op over a "no value yet" state (iterables of any kind).
@inline function _foldchunk(op, acc, chunk)
    for x in chunk
        acc = acc === novalue ? x : op(acc, x)
    end
    return acc
end
@inline _comb(op, a, b) = a === novalue ? b : b === novalue ? a : op(a, b)

_isemptychunk(chunk) = isempty(chunk)

struct Sum <: Aggregator end
init(::Sum) = novalue
partial(::Sum, acc, chunk) = _isemptychunk(chunk) ? acc : _comb(+, acc, sum(chunk))
combine(::Sum, a, b) = _comb(+, a, b)
final(::Sum, acc) = acc === novalue ? 0 : acc
iscommutative(::Sum) = true
neutral(::Sum) = novalue

struct Prod <: Aggregator end
init(::Prod) = novalue
partial(::Prod, acc, chunk) = _isemptychunk(chunk) ? acc : _comb(*, acc, prod(chunk))
combine(::Prod, a, b) = _comb(*, a, b)
final(::Prod, acc) = acc === novalue ? 1 : acc
iscommutative(::Prod) = true
neutral(::Prod) = novalue

struct Count <: Aggregator end
init(::Count) = 0
function partial(::Count, acc, chunk)
    n = acc
    for _ in chunk
        n += 1
    end
    return n
end
combine(::Count, a, b) = a + b
iscommutative(::Count) = true
neutral(::Count) = 0

struct CountTrue <: Aggregator end
init(::CountTrue) = 0
partial(::CountTrue, acc, chunk) = _isemptychunk(chunk) ? acc : acc + count(chunk)   # Bool only, like Base
combine(::CountTrue, a, b) = a + b
iscommutative(::CountTrue) = true
neutral(::CountTrue) = 0

# any/all: three-valued, like Base (`any([missing, true]) == true`, `any([missing]) === missing`).
_checkbool(f, x) = x isa Union{Bool, Missing} ? x : throw(TypeError(f, "", Bool, x))
struct AnyM <: Aggregator end
init(::AnyM) = false
function partial(::AnyM, acc, chunk)
    for x in chunk
        acc = acc | _checkbool(:any, x)
    end
    return acc
end
combine(::AnyM, a, b) = a | b
iscommutative(::AnyM) = true
neutral(::AnyM) = false

struct AllM <: Aggregator end
init(::AllM) = true
function partial(::AllM, acc, chunk)
    for x in chunk
        acc = acc & _checkbool(:all, x)
    end
    return acc
end
combine(::AllM, a, b) = a & b
iscommutative(::AllM) = true
neutral(::AllM) = true

# Semigroups: empty input throws CC-007's type on every Julia (ArgumentError / BoundsError).
_empty(name) = throw(ArgumentError("$name of an empty collection is undefined (no value)"))

struct Max <: Aggregator end
init(::Max) = novalue
partial(::Max, acc, chunk) = _isemptychunk(chunk) ? acc : _comb(max, acc, maximum(chunk))
combine(::Max, a, b) = _comb(max, a, b)
final(::Max, acc) = acc === novalue ? _empty("maximum") : acc
iscommutative(::Max) = true

struct Min <: Aggregator end
init(::Min) = novalue
partial(::Min, acc, chunk) = _isemptychunk(chunk) ? acc : _comb(min, acc, minimum(chunk))
combine(::Min, a, b) = _comb(min, a, b)
final(::Min, acc) = acc === novalue ? _empty("minimum") : acc
iscommutative(::Min) = true

_ext(a, b) = (min(a[1], b[1]), max(a[2], b[2]))
struct Extrema <: Aggregator end
init(::Extrema) = novalue
partial(::Extrema, acc, chunk) = _isemptychunk(chunk) ? acc : _comb(_ext, acc, extrema(chunk))
combine(::Extrema, a, b) = _comb(_ext, a, b)
final(::Extrema, acc) = acc === novalue ? _empty("extrema") : acc
iscommutative(::Extrema) = true

# First/Last wrap the value so a stored `nothing`/`missing` is never confused with "no value".
struct Some1{T}
    x::T
end
struct First <: Aggregator end
init(::First) = novalue
function partial(::First, acc, chunk)
    acc === novalue || return acc
    for x in chunk
        return Some1(x)
    end
    return acc
end
combine(::First, a, b) = a === novalue ? b : a
final(::First, acc) = acc === novalue ? throw(BoundsError(Any[], 1)) : acc.x

struct Last <: Aggregator end
init(::Last) = novalue
function partial(::Last, acc, chunk)
    for x in chunk
        acc = Some1(x)
    end
    return acc
end
combine(::Last, a, b) = b === novalue ? a : b
final(::Last, acc) = acc === novalue ? throw(BoundsError(Any[], 0)) : acc.x

# Mean: a float sum plus a count, so Int data never overflows (prototype regression 1).
struct Mean <: Aggregator end
init(::Mean) = (false, 0)
function partial(::Mean, acc, chunk)
    s, n = acc
    for x in chunk
        s += float(x)
        n += 1
    end
    return (s, n)
end
combine(::Mean, a, b) = (a[1] + b[1], a[2] + b[2])
final(::Mean, acc) = acc[1] / acc[2]
iscommutative(::Mean) = true
neutral(::Mean) = (false, 0)

"""
    Moments(; std = false, corrected = true)

Variance (or standard deviation) by Chan's parallel merge, with a "no value yet" state
(CC-006). The constructor is PROVISIONAL upstream.
"""
struct Moments <: Aggregator
    std::Bool
    corrected::Bool
end
Moments(; std::Bool = false, corrected::Bool = true) = Moments(std, corrected)
init(::Moments) = novalue
function _moments(chunk)
    n = 0
    s = false
    for x in chunk
        s += float(x)
        n += 1
    end
    m = s / n
    M2 = false
    for x in chunk
        M2 += abs2(float(x) - m)
    end
    return (n, m, M2)
end
function _chan(a, b)
    na, ma, Ma = a
    nb, mb, Mb = b
    n = na + nb
    δ = mb - ma
    return (n, ma + δ * nb / n, Ma + Mb + δ^2 * na * nb / n)
end
partial(::Moments, acc, chunk) = _isemptychunk(chunk) ? acc : _comb(_chan, acc, _moments(chunk))
combine(::Moments, a, b) = _comb(_chan, a, b)
function final(m::Moments, acc)
    acc === novalue && return NaN
    n, _, M2 = acc
    v = M2 / (m.corrected ? n - 1 : n)
    return m.std ? sqrt(v) : v
end
iscommutative(::Moments) = true

"""
    ReduceM(op; neutral = NoValue(), commutative = false)

`reduce(op, v)` as an aggregator. Empty input throws `ArgumentError` unless a neutral element is
declared (CC-006). The keyword names are PROVISIONAL upstream.
"""
struct ReduceM{F, N} <: Aggregator
    op::F
    neutral::N
    commutative::Bool
end
ReduceM(op; neutral = novalue, commutative::Bool = false) = ReduceM(op, neutral, commutative)
init(m::ReduceM) = m.neutral === novalue ? novalue : m.neutral
partial(m::ReduceM, acc, chunk) = _foldchunk(m.op, acc, chunk)
combine(m::ReduceM, a, b) = _comb(m.op, a, b)
final(m::ReduceM, acc) = acc === novalue ? _empty("reduce") : acc
iscommutative(m::ReduceM) = m.commutative
neutral(m::ReduceM) = m.neutral === novalue ? throw(ArgumentError("ReduceM($(m.op)) has no declared neutral element")) : m.neutral

"`MapM(f, inner)`: `inner` over `f` of each element."
struct MapM{F, A} <: Aggregator
    f::F
    inner::A
end
init(m::MapM) = init(m.inner)
partial(m::MapM, acc, chunk) = partial(m.inner, acc, Iterators.map(m.f, chunk))
combine(m::MapM, a, b) = combine(m.inner, a, b)
final(m::MapM, acc) = final(m.inner, acc)
iscommutative(m::MapM) = iscommutative(m.inner)
neutral(m::MapM) = neutral(m.inner)

# Printing: the Base name the aggregator stands for.
Base.show(io::IO, a::Aggregator) = print(io, nameof(typeof(a)), "()")
Base.show(io::IO, m::Moments) = print(io, "Moments(std = ", m.std, ", corrected = ", m.corrected, ")")
Base.show(io::IO, m::ReduceM) = print(io, "ReduceM(", m.op, ")")
Base.show(io::IO, m::MapM) = print(io, "MapM(", m.f, ", ", m.inner, ")")

# ---------------------------------------------------------------------------------------------
# Transducers (ChuiCore ADR-0003): immutable structs transforming reducing functions.

"Supertype of the stand-in transducers."
abstract type Transducer end
struct Map{F} <: Transducer
    f::F
end
struct Filter{P} <: Transducer
    p::P
end
struct MapCat{F} <: Transducer
    f::F
end
struct Take <: Transducer
    n::Int
end
struct Composed{T <: Tuple} <: Transducer
    xfs::T
end

"Early-termination signal of a reducing function."
struct Reduced{T}
    value::T
end
unreduced(x) = x isa Reduced ? x.value : x

"`isstateless(xf)`: fail-closed; `true` only for `Map`, `Filter`, `MapCat` (and compositions of them)."
isstateless(::Any) = false
isstateless(::Union{Map, Filter, MapCat}) = true
isstateless(x::Composed) = all(isstateless, x.xfs)

xfs(x::Transducer) = (x,)
xfs(x::Composed) = x.xfs
⨟(a::Transducer, b::Transducer) = Composed((xfs(a)..., xfs(b)...))

"`asrf(xf, rf)`: the reducing function `xf` makes of `rf`."
asrf(x::Map, rf) = (acc, v) -> rf(acc, x.f(v))
asrf(x::Filter, rf) = (acc, v) -> x.p(v) ? rf(acc, v) : acc
asrf(x::MapCat, rf) = function (acc, v)
    for u in x.f(v)
        acc = rf(acc, u)
        acc isa Reduced && return acc
    end
    return acc
end
function asrf(x::Take, rf)
    seen = Ref(0)
    return function (acc, v)
        seen[] >= x.n && return Reduced(acc)
        seen[] += 1
        acc = rf(acc, v)
        return (acc isa Reduced || seen[] < x.n) ? acc : Reduced(acc)
    end
end
asrf(x::Composed, rf) = foldr(asrf, x.xfs; init = rf)

"`foldxl(rf, xf, itr; init)`: sequential left fold of `itr` through `xf`, honouring `Reduced`."
function foldxl(rf, xf::Transducer, itr; init)
    f = asrf(xf, rf)
    acc = init
    for v in itr
        acc = f(acc, v)
        acc isa Reduced && return acc.value
    end
    return acc
end

"`eduction(xf, itr)`: the elements of `itr` as transformed by `xf` (a lazy-enough iterable)."
eduction(::Map{typeof(identity)}, itr) = itr
eduction(x::Map, itr) = Iterators.map(x.f, itr)
eduction(x::Filter, itr) = Iterators.filter(x.p, itr)
eduction(x::Transducer, itr) = foldxl(push!, x, itr; init = Any[])

"""
    aggregate(agg, xf, parts)

The plain-fold entry point (ChuiCore ADR-0003 rule 6): `partial` per part through `xf`, `combine`
in part order (CC-005), then `final`.
"""
function aggregate(agg, xf::Transducer, parts)
    acc = init(agg)
    for p in parts
        acc = combine(agg, acc, partial(agg, init(agg), eduction(xf, p)))
    end
    return final(agg, acc)
end

# ---------------------------------------------------------------------------------------------
# Recursion schemes (ChuiCore R6, main b4f1ca3 and later, unreleased): the Functor class's `fmap`
# through a constructor-class tag and a typed style argument (ChuiCore rule N5), `project`, and
# `cata`/`para`/`ana` with ChuiCore's semantics. A node type that registers `fmap` is its own base
# functor (`project(x) = x`), so the schemes traverse it without `Fix` wrappers. ChuiFrames' plan
# nodes register here (src/lazy/plan.jl); the stand-ins move to ChuiCore at its release
# (ADR-0014 rule 3).

"The fallback constructor-class tag (ChuiCore's `NoTag`)."
struct NoTag end
"`constructorclass(::Type{T})`: the tag of `T` (ChuiCore); `NoTag()` unless registered."
constructorclass(::Type) = NoTag()

"The Functor class styles (ChuiCore's `IsFunctor`/`NotFunctor`)."
struct IsFunctor end
struct NotFunctor end
"`FunctorStyle(tag)`: `IsFunctor()` for a registered tag, else `NotFunctor()`."
FunctorStyle(::Any) = NotFunctor()

"""
    fmap(f, x)

Functor map: `fmap(FunctorStyle(constructorclass(typeof(x))), f, x)`. Instances add the
3-argument method with the style argument typed, `fmap(::IsFunctor, f, x::T)` (ChuiCore N5).
"""
fmap(f, x) = fmap(FunctorStyle(constructorclass(typeof(x))), f, x)
fmap(::NotFunctor, f, x) =
    throw(ArgumentError("$(typeof(x)) is not a Functor: register it with constructorclass and FunctorStyle"))

"`project(x)`: the layer a scheme maps over; a node type with its own `fmap` is its own layer."
project(x) = x

struct _Cata{A} <: Function
    alg::A
end
(c::_Cata)(x) = c.alg(fmap(c, project(x)))
"`cata(alg, x)`: fold; `alg` sees one layer whose holes hold the children's results."
cata(alg, x) = _Cata(alg)(x)

struct _Para{A} <: Function
    alg::A
end
(p::_Para)(x) = p.alg(fmap(c -> (c, p(c)), project(x)))
"`para(alg, x)`: fold whose holes are `(original, result)` tuples (ChuiCore R6)."
para(alg, x) = _Para(alg)(x)

struct _Ana{C, E} <: Function
    coalg::C
    embed::E
end
(a::_Ana)(seed) = a.embed(fmap(a, a.coalg(seed)))
"`ana(coalg, seed; embed)`: unfold; `embed = identity` builds a tree of bare layers."
ana(coalg, seed; embed) = _Ana(coalg, embed)(seed)

end # module Upstream
