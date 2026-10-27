# The tdd.jl classifier (factory 0.3.0; spec §3.3, §3.4). Top-level definitions, included after
# _common.jl (it uses `git`), never run on its own and no `module` of its own.
#
# It reads a TestItemRunner run's combined output and says, per requested `@testitem`, why it failed:
# ASSERTION, BEHAVIOUR (red), WRONG-REASON, PASSED, NOT-RUN, COLLATERAL (not red). Only failure header
# lines are parsed (stacktrace line numbers for the item file are wrong); a header belongs to the
# item whose span holds its line.

"One `@testitem`: its name, file, first and last line, and the names in its `setup = [...]`."
struct ItemSpan
    name::String
    file::String
    first::Int
    last::Int
    setup::Vector{String}
end

const WRONG_REASON = Symbol("WRONG-REASON")
const NOT_RUN = Symbol("NOT-RUN")

"The failure header, the same on Julia 1.10 and 1.13 (measured, fixtures/tdd/README.md)."
const HEADER_RE = r"^(.+): (Test Failed|Error During Test) at (.+):(\d+)$"

"""
Exceptions that make a failure the wrong reason (spec §3.3): a missing name or a typo, a file that
does not parse or load, a missing package, a package that fails to precompile. Matched against an
exception line with one `LoadError: ` removed, and against a `@test_throws` block's `Thrown:` type or
message. The precompile lines are measured (fixtures/tdd/README.md, `precompile-fail`): 1.13's first
exception line is `The following 1 package failed to precompile:`, 1.10's is
`Failed to precompile <Pkg> [<uuid>] to ...`.
"""
const REJECTED = (
    r"^UndefVarError\b",
    r"^ParseError\b",
    r"^syntax:",
    r"^LoadError\b",
    r"^SystemError: opening file",
    r"^(ArgumentError: )?Package \S+ not found",
    r"^ArgumentError: Package\b",
    r"^Failed to precompile \S+ \[",
    r"^The following \d+ .*failed to precompile",
    r"^Unexpected Pass$",   # review M1: a `@test_broken` that now holds is no red (or kill)
)

rejected(s::AbstractString) = any(re -> occursin(re, s), REJECTED)

# ---------------------------------------------------------------------------------------------
# Spans

_is_macro(ex, name) = ex isa Expr && ex.head === :macrocall && !isempty(ex.args) && ex.args[1] === Symbol(name)

"The largest source line any `LineNumberNode` inside `ex` names (0 for none)."
function _max_line(ex)
    ex isa LineNumberNode && return ex.line
    ex isa Expr || return 0
    return maximum((_max_line(a) for a in ex.args); init = 0)
end

"Top-level expressions of `text` with their lines; `nothing` when the text does not parse."
function _toplevel(text, file)
    top = try
        Meta.parseall(text; filename = file)
    catch
        return nothing
    end
    out = Tuple{Int, Any}[]
    line = 0
    for ex in top.args
        if ex isa LineNumberNode
            line = ex.line
        elseif ex isa Expr && ex.head in (:error, :incomplete)
            return nothing
        else
            push!(out, (line, ex))
        end
    end
    return out
end

"The `setup = [...]` names of a `@testitem` call, in order."
function _setup(ex)
    for a in ex.args[4:end]
        if a isa Expr && a.head === :(=) && a.args[1] === :setup && a.args[2] isa Expr && a.args[2].head === :vect
            return String[string(x) for x in a.args[2].args]
        end
    end
    return String[]
end

"""
    item_spans(text, file) -> Vector{ItemSpan}

The top-level `@testitem`s in `text` (from `Meta.parseall` line info), `file` stored verbatim. `first`
is the `@testitem` line, `last` the last line any statement inside it names. Empty when the text does
not parse.
"""
function item_spans(text::AbstractString, file::AbstractString)
    spans = ItemSpan[]
    top = _toplevel(text, file)
    top === nothing && return spans
    for (line, ex) in top
        _is_macro(ex, "@testitem") && length(ex.args) >= 3 && ex.args[3] isa AbstractString || continue
        first = ex.args[2] isa LineNumberNode ? ex.args[2].line : line
        push!(spans, ItemSpan(ex.args[3], String(file), first, max(first, _max_line(ex)), _setup(ex)))
    end
    return spans
end

"The names of the top-level `@testmodule`s and `@testsnippet`s in `text`."
function module_names(text::AbstractString)
    top = _toplevel(text, "none")
    top === nothing && return String[]
    return String[
        string(ex.args[3]) for (_, ex) in top
            if (_is_macro(ex, "@testmodule") || _is_macro(ex, "@testsnippet")) && length(ex.args) >= 3
    ]
end

"`name => expression without line numbers` (`strip_lines!`, _common.jl: macrocall line slots too, so
an item that only moved is unchanged) for each item (`@testitem`) or module in `text`."
function _defs(text, file, modules::Bool)
    d = Dict{String, Any}()
    top = _toplevel(text, file)
    top === nothing && return d
    for (_, ex) in top
        is = modules ? (_is_macro(ex, "@testmodule") || _is_macro(ex, "@testsnippet")) : _is_macro(ex, "@testitem")
        is && length(ex.args) >= 3 || continue
        d[string(ex.args[3])] = strip_lines!(deepcopy(Expr(:block, ex.args[3:end]...)))
    end
    return d
end

_is_test_file(p) = startswith(p, "test/") && endswith(p, ".jl")
_show(root, rev, path) = something(git(root, "show", "$rev:$path"), "")

"""
    requested(root, rev) -> (red = Vector{ItemSpan}, must_pass = Vector{ItemSpan})

The items commit `rev` added or changed (`red`), and the unchanged items whose `setup = [...]` names a
`@testmodule`/`@testsnippet` it added or changed (`must_pass`). Spans are as of `rev`, files relative
to `root`. A root commit compares against an empty tree.
"""
function requested(root, rev)
    parent = git(root, "rev-parse", "--verify", "--quiet", "$rev^")
    changed = if parent === nothing
        split(something(git(root, "ls-tree", "-r", "--name-only", rev), ""), '\n'; keepempty = false)
    else
        split(something(git(root, "diff", "--name-only", parent, rev), ""), '\n'; keepempty = false)
    end
    red = ItemSpan[]
    mods = Set{String}()
    for path in filter(_is_test_file, changed)
        new = _show(root, rev, path)
        old = parent === nothing ? "" : _show(root, parent, path)
        oldi = _defs(old, path, false)
        newi = _defs(new, path, false)
        for s in item_spans(new, path)
            get(oldi, s.name, nothing) == newi[s.name] || push!(red, s)
        end
        oldm = _defs(old, path, true)
        newm = _defs(new, path, true)
        for k in union(keys(oldm), keys(newm))
            get(oldm, k, nothing) == get(newm, k, nothing) || push!(mods, k)
        end
    end
    must = ItemSpan[]
    if !isempty(mods)
        tracked = split(something(git(root, "ls-tree", "-r", "--name-only", rev), ""), '\n'; keepempty = false)
        for path in filter(_is_test_file, tracked), s in item_spans(_show(root, rev, path), path)
            any(r -> r.name == s.name && r.file == s.file, red) && continue
            any(in(mods), s.setup) && push!(must, s)
        end
    end
    return (red = red, must_pass = must)
end

# ---------------------------------------------------------------------------------------------
# Headers

const EXC_MARKERS = ("Test threw exception", "Got exception outside of a @test")

"The part of a path from its last `/test/` on, so absolute and `~/` forms compare equal."
_test_rel(p) = (m = findlast("/test/", p); m === nothing ? p : p[(first(m) + 1):end])

"""
True when the last package directory (`/src/`, `/ext/`, `/test/`) in `p` is `test/`. Decided by the
last one because the package itself may sit under some `test/` (the fixtures do), and frames print
`~/` paths while headers print absolute ones, so a root prefix cannot be compared.
"""
function _is_test_path(p)
    last_at(d) = (m = findlast(d, p); m === nothing ? 0 : first(m))
    t = last_at("/test/")
    return t > 0 && t > last_at("/src/") && t > last_at("/ext/")
end

"The `file:line` of a stacktrace `@` line (its last token, `[inlined]` dropped)."
function _frame_loc(line)
    m = match(r"(\S+):(\d+)(?: \[inlined\])?\s*$", line)
    return m === nothing ? nothing : string(m.captures[1], ":", m.captures[2])
end

"`(header, rejectable thrown text)` per header line, in output order."
function _blocks(output::AbstractString)
    lines = split(output, '\n')
    starts = Int[]
    for (i, l) in pairs(lines)
        match(HEADER_RE, rstrip(l, '\r')) === nothing || push!(starts, i)
    end
    res = []
    for (k, i) in pairs(starts)
        m = match(HEADER_RE, rstrip(lines[i], '\r'))
        stop = k < length(starts) ? starts[k + 1] - 1 : length(lines)
        for j in (i + 1):stop
            startswith(lines[j], "Test Summary:") && (stop = j - 1; break)
        end
        block = [strip(l) for l in lines[(i + 1):stop]]
        # exception line: the first after the markers (`Test threw exception`, `Expression:`, ...),
        # skipping `Expression:` and `Context:` (1.13 prints `Context: v = 1` inside `@testset let`)
        exc = ""
        skip(l) = isempty(l) || startswith(l, "Expression:") || startswith(l, "Context:")
        if !isempty(block) && block[1] == "Unexpected Pass"
            exc = "Unexpected Pass"                    # a `@test_broken` that holds (review M1)
        elseif (mi = findfirst(l -> l in EXC_MARKERS || startswith(l, "Expression:"), block)) !== nothing
            j = mi + 1
            while j <= length(block) && skip(block[j])
                j += 1
            end
            j <= length(block) && (exc = String(block[j]))
        end
        startswith(exc, "LoadError: ") && (exc = exc[(length("LoadError: ") + 1):end])
        # @test_throws: the type after `Thrown: `, and its message when the next line carries one
        thrown = nothing
        thrown_text = ""
        ti = findfirst(l -> startswith(l, "Thrown: "), block)
        if ti !== nothing
            thrown = String(strip(block[ti][(length("Thrown: ") + 1):end]))
            nxt = ti < length(block) ? block[ti + 1] : ""
            thrown_text = startswith(nxt, thrown) ? String(nxt) : thrown
        end
        # HELPER: the first stacktrace frame is another test/ file
        helper = nothing
        fi = findfirst(l -> startswith(l, "[1] "), block)
        if fi !== nothing && fi < length(block) && startswith(block[fi + 1], "@ ")
            loc = _frame_loc(block[fi + 1])
            if loc !== nothing
                f = loc[1:(findlast(':', loc) - 1)]
                _is_test_path(f) && _test_rel(f) != _test_rel(m.captures[3]) && (helper = loc)
            end
        end
        hdr = (
            prefix = String(m.captures[1]), kind = String(m.captures[2]), file = String(m.captures[3]),
            line = parse(Int, m.captures[4]), exc = exc, thrown = thrown, helper = helper,
        )
        push!(res, (hdr, thrown_text))
    end
    return res
end

"""
    headers(output) -> Vector{NamedTuple}

One `(prefix, kind, file, line, exc, thrown, helper)` per failure header line, in output order.
"""
headers(output::AbstractString) = [b[1] for b in _blocks(output)]

"The class of one header block."
function _header_class(hdr, thrown_text)
    if hdr.kind == "Test Failed"
        return hdr.thrown !== nothing && rejected(thrown_text) ? WRONG_REASON : :ASSERTION
    end
    return rejected(hdr.exc) ? WRONG_REASON : :BEHAVIOUR
end

_in_span(hdr, s::ItemSpan) =
    s.first <= hdr.line <= s.last && (hdr.file == s.file || endswith(hdr.file, "/" * s.file))

# ---------------------------------------------------------------------------------------------
# Classification

"""
    classify(output, red, must_pass, matched; termsignal = 0) -> Vector{Pair{String, Symbol}}

One pair per `red` item, in order; then each `must_pass` item that is not fine (COLLATERAL, NOT-RUN,
WRONG-REASON); then `"<file>:<line>" => WRONG-REASON` for each header in no given span. A run without
a `Test Summary:`, or whose process got a signal, makes every red and must_pass item WRONG-REASON.
"""
function classify(output::AbstractString, red, must_pass, matched::Set{String}; termsignal = 0)
    if termsignal != 0 || !occursin("Test Summary:", output)
        return Pair{String, Symbol}[s.name => WRONG_REASON for s in vcat(red, must_pass)]
    end
    spans = vcat(red, must_pass)
    classes = [Symbol[] for _ in spans]
    orphans = Pair{String, Symbol}[]
    for (hdr, tt) in _blocks(output)
        i = findfirst(s -> _in_span(hdr, s), spans)
        if i === nothing
            push!(orphans, "$(hdr.file):$(hdr.line)" => WRONG_REASON)
        else
            push!(classes[i], _header_class(hdr, tt))
        end
    end
    res = Pair{String, Symbol}[]
    for (i, s) in pairs(spans)
        c = classes[i]
        isred = i <= length(red)
        class = if !(s.name in matched)
            NOT_RUN
        elseif isempty(c)
            isred ? :PASSED : nothing
        elseif !isred
            :COLLATERAL
        else
            WRONG_REASON in c ? WRONG_REASON : first(c)
        end
        class === nothing || push!(res, s.name => class)
    end
    return append!(res, orphans)
end

"True iff `result` is non-empty and every class is ASSERTION or BEHAVIOUR."
red_ok(result) = !isempty(result) && all(p -> p.second in (:ASSERTION, :BEHAVIOUR), result)

"""
    report(io, result, hdrs)

Each item with its class, then each failure header; a header whose first stacktrace frame is another
`test/` file gets `HELPER <file>:<line>` (report only: the class is unchanged).
"""
function report(io::IO, result, hdrs)
    for (name, class) in result
        println(io, "  ", rpad(string(class), 13), name)
    end
    for h in hdrs
        println(io, "    ", h.prefix, ": ", h.kind, " at ", h.file, ":", h.line, isempty(h.exc) ? "" : "  ($(h.exc))")
        h.helper === nothing || println(io, "      HELPER ", h.helper)
    end
    return nothing
end
