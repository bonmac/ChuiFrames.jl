# Name-conflict banner: a STAND-IN for the piece ChuiCore owns (ADR-0014; test/contracts/
# chui-core.md, PROVISIONAL "Name-conflict banner"). Internal and not exported (ADR-0014 rule 2);
# it is replaced by ChuiCore's when that piece is released.
#
# R reference (`library(tidyverse)`, tidyverse 2.0.0):
#   ── Conflicts ──────────────────────────────────────────── tidyverse_conflicts() ──
#   ✖ dplyr::filter() masks stats::filter()
#   ✖ dplyr::lag()    masks stats::lag()
#   ℹ Use the conflicted package (<http://conflicted.r-lib.org/>) to force all conflicts to become errors
# Julia adaptation: Julia does not mask. When two modules used in `Main` export different
# bindings of one name, an unqualified use is ambiguous (an error or warning), so the line reads
# "conflicts with", and the hint says how to choose one.
#
# Which modules are scanned: the modules bound in `Main` (what `using X` / `import X` binds),
# found with public API only; `Base.loaded_modules` is internal. A module that is only
# `import`ed counts too, which can over-report; R's banner likewise checks the attached packages.

function _main_modules()
    ms = Module[]
    for n in names(Main; all = true, imported = true)
        isdefined(Main, n) || continue
        m = getfield(Main, n)
        m isa Module && m !== Main && push!(ms, m)
    end
    return ms
end

"""
    binding_conflicts(mod, others = <modules bound in Main>) -> Vector{Pair{Symbol,Vector{Module}}}

For each name `mod` exports (sorted), the modules in `others` other than `mod` that export a
**different binding** of that name. Re-exporting the same binding, or adding methods to the same
function, is not a conflict.
"""
function binding_conflicts(mod::Module, others = _main_modules())
    out = Pair{Symbol, Vector{Module}}[]
    for n in sort!(names(mod))
        (n === nameof(mod) || !Base.isexported(mod, n) || !isdefined(mod, n)) && continue
        b = getfield(mod, n)
        ms = Module[]
        for M in others
            (M === mod || M in ms) && continue
            Base.isexported(M, n) && isdefined(M, n) && getfield(M, n) !== b && push!(ms, M)
        end
        isempty(ms) || push!(out, n => sort!(ms; by = nameof))
    end
    return out
end

_qualified(M::Module, n::Symbol) = string(nameof(M), ".", n, getfield(M, n) isa Function ? "()" : "")

"""
    conflict_banner(io, mod, others = <modules bound in Main>)

Print dplyr's "Conflicts" banner for [`binding_conflicts`](@ref)`(mod, others)`; print nothing
when there are none.
"""
function conflict_banner(io::IO, mod::Module, others = _main_modules())
    cs = binding_conflicts(mod, others)
    isempty(cs) && return nothing
    color = get(io, :color, false)::Bool
    width = displaysize(io)[2]
    left, right = "── Conflicts ", " ChuiFrames.conflict_banner() ──"
    rule = "─"^max(width - textwidth(left) - textwidth(right), 2)
    println(io, _dim(string(left, rule, right), color))
    lhs = [_qualified(mod, n) for (n, _) in cs]
    wl = maximum(textwidth, lhs)
    for ((n, ms), l) in zip(cs, lhs)
        cross = color ? "\e[31m✖\e[39m" : "✖"
        println(io, cross, " ", pad_right(l, wl), " conflicts with ", join((_qualified(M, n) for M in ms), ", "))
    end
    n = first(cs[1])
    info = color ? "\e[36mℹ\e[39m" : "ℹ"
    println(io, info, " Qualify the name (", nameof(mod), ".", n, ") or choose one with `using ", nameof(mod), ": ", n, "`")
    println(io, info, " Set CHUI_QUIET_CONFLICTS=1 to hide this banner")
    return nothing
end

"`_banner_enabled(interactive, env)`: show the banner in interactive sessions unless `CHUI_QUIET_CONFLICTS` is `1`/`true`."
_banner_enabled(interactive::Bool, env = ENV) =
    interactive && !(lowercase(strip(get(env, "CHUI_QUIET_CONFLICTS", ""))) in ("1", "true"))

# Called from ChuiFrames.__init__.
function _init_banner()
    _banner_enabled(isinteractive()) || return nothing
    try
        conflict_banner(stderr, @__MODULE__)
    catch err
        @debug "ChuiFrames: the conflict banner failed" exception = err
    end
    return nothing
end
