# Snapshot (golden-output) tests of `explain` on join plans (phase-4 spec
# docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md §1.4). Goldens live in
# test/snapshots/lazy_join/ (linear plans keep their goldens in test/snapshots/lazy/). To
# (re)write them after an intended change:
#
#     CHUI_UPDATE_SNAPSHOTS=1 julia --startup-file=no scripts/ci.jl test -- snapshot
#
# then review `git diff test/snapshots/`. Tagged `:snapshot`: stable Julia only.

@testitem "snapshot: explain on join plans" tags = [:snapshot] setup = [Force] begin
    const ⨟ = ChuiFrames.Upstream.:⨟
    dir = joinpath(pkgdir(ChuiFrames), "test", "snapshots", "lazy_join")
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
    x = Frame(k = [1, 2, 3, 2], v = [1.0, 2.0, 3.0, 4.0], s = ["a", "b", "c", "d"])
    y = Frame(k = [2, 3], w = [20, 30])
    z = Frame(w = [20, 40], u = ["p", "q"])
    ex(q) = sprint((io, q) -> explain(io, q; morsel = 2), q)
    # shape (a): broadcast, build y, x streams; a filter pushed to x and a projection per side
    qa = (inner_join(y; by = :k) ⨟ filter(c.v .> 1.5) ⨟ select(:k, :w))(lazy(x))
    check("explain_join_broadcast_y", ex(qa))
    # shape (b) and (c), forced
    qb = left_join(y; by = :k)(lazy(x))
    check("explain_join_broadcast_x", withforce(() -> ex(qb), ChuiFrames._FORCE_JOIN => :broadcast_x))
    check("explain_join_partitioned", withforce(() -> ex(qb), ChuiFrames._FORCE_JOIN => :partitioned_y))
    # a join of a join, a right join with a tail, and a cross join
    qt = (inner_join(y; by = :k) ⨟ right_join(lazy(z) |> filter(c.w .> 0); by = :w))(lazy(x))
    check("explain_join_tree", ex(qt))
    check("explain_cross_join", ex(cross_join(z)(lazy(y))))
end
