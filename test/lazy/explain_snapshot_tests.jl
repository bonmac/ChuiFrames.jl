# Snapshot (golden-output) tests of `explain` and `code_lowered` (ADR-0003 rule 13; spec §7).
# Goldens live in test/snapshots/lazy/. To (re)write them after an intended change:
#
#     CHUI_UPDATE_SNAPSHOTS=1 julia --startup-file=no scripts/ci.jl test -- snapshot
#
# then review `git diff test/snapshots/`. Tagged `:snapshot`: stable Julia only (the lowered
# code's printing changes between Julia versions).

@testitem "snapshot: explain and code_lowered" tags = [:snapshot] begin
    using Statistics
    const ⨟ = ChuiFrames.Upstream.:⨟
    dir = joinpath(pkgdir(ChuiFrames), "test", "snapshots", "lazy")
    update = get(ENV, "CHUI_UPDATE_SNAPSHOTS", "") in ("1", "true")
    function check(name, out)
        path = joinpath(dir, name * ".txt")
        if update
            mkpath(dir)
            write(path, out)
            @info "snapshot written" path
        end
        @test isfile(path)
        isfile(path) || return nothing
        golden = read(path, String)
        golden == out || @info "snapshot mismatch: $name" expected = golden got = out
        @test golden == out
        return nothing
    end
    t = (g = ["a", "b", "a", "c", "b", "a"], x = [1.0, NaN, 4.0, missing, 5.0, 6.0], y = [1, 2, 3, 4, 5, 6], s = ["p", "q", "r", "s", "t", "u"])
    q = (
        rename(yy = :y) ⨟ filter(c.x .> 3.5, c.yy .>= 2) ⨟ select(:g, :x, :yy) ⨟
            mutate(z = c.yy .* 2) ⨟ group_by(:g) ⨟ summarise(n = n_rows(), m = mean(c.z))
    )(lazy(t))
    check("explain_pipeline", sprint((io, x) -> explain(io, x; morsel = 2), q))
    check("code_lowered_pipeline", sprint(code_lowered, q))
    h = (filter(c.y .> 1) ⨟ head(2))(lazy(t))
    check("explain_limit", sprint((io, x) -> explain(io, x; morsel = 2), h))
    b = (mutate(v = c.y .- mean(c.y)) ⨟ filter(c.v .> 0))(lazy(t))
    check("explain_barrier", sprint(explain, b))
end
