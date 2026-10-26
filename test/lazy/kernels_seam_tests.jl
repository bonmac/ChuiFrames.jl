# The phase-4 seam (spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §0): the estimated row count handed to `stage_kernel`, and the interpreter kernel and
# `run_rest` reproducing the phase-3 path.

@testitem "seam: _estimated_rows" tags = [:unit] begin
    using Tables
    struct Int32Rows <: ChuiFrames.Source end
    ChuiFrames.row_count(::Int32Rows) = (Int32(7), false)
    struct NoRows <: ChuiFrames.Source end

    f = Frame((x = [1, 2, 3], y = ["a", "b", "c"]))
    @test ChuiFrames._estimated_rows(ChuiFrames.FrameSource(f)) === 3
    @test ChuiFrames._estimated_rows(Int32Rows()) === 7       # an inexact, non-Int count: an upper bound, as Int
    @test ChuiFrames._estimated_rows(NoRows()) === nothing    # the default `row_count`
end

@testitem "seam: interpreter kernel and run_rest match the eager steps" tags = [:unit] begin
    using Tables
    const ⨟ = ChuiFrames.Upstream.:⨟
    t = (g = ["a", "b", "a", "c"], x = [1.0, NaN, -0.0, 4.0], y = [1, 2, 3, 4])
    q = (filter(c.y .> 1) ⨟ mutate(z = c.y .* 2) ⨟ arrange(:g))(lazy(t))
    ph = ChuiFrames.physical(ChuiFrames.optimize(q).plan)
    @test !isempty(ph.stage)
    @test !isempty(ph.rest)
    f = Frame(t)
    f1 = isempty(ph.engine) ? f : ChuiFrames.apply(ChuiFrames.FilterStep(ph.engine, false), f)
    staged = ChuiFrames.stage_kernel(ph, 4)(f1)
    eager = foldl((acc, s) -> ChuiFrames.apply(s, acc), ph.stage; init = f1)
    @test isequal(Tables.columntable(staged), Tables.columntable(eager))
    out = ChuiFrames.run_rest(ph, staged; morsel = 2, threads = false)
    @test isequal(Tables.columntable(out), Tables.columntable(collect(q)))
end
