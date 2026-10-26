# Optimization checks for the compiled stage kernels (phase-4 spec §3.3, §4; p4-codegen):
# the fused row loop and the per-call register allocation have no runtime dispatch on concrete
# inputs. Included by runjet.jl (JET and the package are loaded; `PKG` is the package module).

@testset "opt: compiled stage kernel row loop" begin
    CF = PKG
    ⨟ = CF.Upstream.:⨟
    t = (x = [1.5, -0.0, NaN, 2.0], y = [1, 2, 3, 4], s = ["a", "b", "pa", "c"])
    stages = Any[
        filter(c.y .> 1) ⨟ mutate(z = c.x .* 2.0 .+ c.y, w = c.z .- 1.0),
        mutate(k = case_when(c.y .> 2 => c.x, c.y .> 1 => 0.5; default = missing)) ⨟ filter_out(c.x .> 1.0),
        filter(startswith.(c.s, "p"), .!(isnan.(c.x))) ⨟ select(:s, q = c.y .+ 1),
        mutate(e = c.x .+ sqrt.(lit(4.0))),
    ]
    f = CF.Frame(t)
    for st in stages
        ph = CF.physical(st(CF.lazy(t)).plan)
        prog = CF._build(ph.stage, CF.take(f, Int[]))
        R = prog.R
        n = f.nrow
        @test_opt CF._allocregs(R, n)
        regs = CF._allocregs(R, n)
        ins = Tuple(f.columns[j] for j in prog.ins)
        cx = (ins, regs, CF._evalscalars(prog.scalars))
        @test_opt CF._rowloop(prog.ops, cx, n, prog.hasfilter)
        @test_opt CF._kernelrun(prog.ops, prog.scalars, R, ins, n, prog.hasfilter)
    end
end
