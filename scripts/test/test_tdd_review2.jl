# Review tests that run packages (spec §3.5, §4.1, §5.2). Included by test_tdd_review.jl, whose header
# holds the rulings. Reuses test_tdd_cli.jl's scratch package (tj_*), test_tdd_backfill.jl's shared
# mutate lane `mut-a` (tb, tb_lane_a, tb_at, tb_exit, tb_evs, ITEM_G, ITEM_P) and th (test_tdd_history.jl).
#
# - B2. `red(root; rev)` classifies the items of `rev` but runs the tree at HEAD and records the
#   evidence as `red-<HEAD sha7>`: E1 then credits HEAD with another commit's run. A `rev` whose sha
#   is not HEAD's is exit 2, with no evidence written; a `rev` that names HEAD (sha, branch) works.
# - Two reds closed by one green: `green` runs every red item of the lane and exits 1, naming the
#   item that still fails.
# - mutate. `--src` must name a file under src/ or ext/; `--expect` a file under test/. Otherwise exit
#   2 before any run, no evidence written. A mutate that does not kill bases its evidence on the
#   mutant run in the scratch (whose tree holds the mutation: `dirty: true`); the evidence must
#   describe the real tree, which is clean, so a survivor alone never trips E4.
#
# Cost: lane rv-two-reds, about three package runs (red x2, green item run x1); mut-a, at most three
# (mutate x2 while the argument checks are missing, a survivor only if mut-a has none yet).

const TRV2_K = "\nfunction k end\n"
const TRV2_STATE = Dict{Symbol, Any}()
"The lane `rv-two-reds`: a stub (h, k), red `h doubles`, red `k triples`; HEAD is the second red."
trv2_two_reds() = get!(TRV2_STATE, :two) do
    d = tj_lane("rv-two-reds")
    commit!(d, Dict("src/TddLane.jl" => tj_src(stub = true, extra = TRV2_K)), "feat: declare h, k\n\nTDD: stub")
    tj_red!(d)
    commit!(d, Dict("test/k_tests.jl" => "@testitem \"k triples\" begin\n    @test TddLane.k(3) == 9\nend\n"), "test: k triples\n\nTDD: red")
    d
end
"The lane's evidence files, name => SHA-1 of the content (short when a test prints it)."
trv2_evdir(d) = (e = joinpath(d, ".lanes", "evidence"); isdir(e) ? Dict(f => bytes2hex(sha1(read(joinpath(e, f)))) for f in readdir(e)) : Dict{String, String}())

@testset "tdd review: red --rev, two reds, mutate arguments (0.3.0)" begin
    tj_testset("red --rev other than HEAD exits 2") do
        d = trv2_two_reds()
        head = tj_head(d)
        prev = readchomp(`git -C $d rev-parse "HEAD~1"`)
        @test prev != head
        code, out = tj_call(tj_mod().red, d; rev = "HEAD~1")              # `h doubles`, a red commit
        @test code == 2
        @test !isfile(tj_ev(d, "red"))                                     # no red-<HEAD sha7>
        @test !isfile(joinpath(d, ".lanes", "evidence", "red-$(first(prev, 7)).txt"))
        @test tj_clean(d)
        code, out = tj_call(tj_mod().red, d; rev = head)                   # HEAD by its sha still works
        @test code == 0
        @test isfile(tj_ev(d, "red")) && occursin("k triples", tj_tdd_part(tj_ev(d, "red")))
    end

    tj_testset("green after two reds fails if one red item still fails") do
        d = trv2_two_reds()
        commit!(d, Dict("src/TddLane.jl" => tj_src(stub = true, fix = true, extra = TRV2_K)), "feat: h doubles\n\nTDD: green")
        code, out = tj_call(tj_mod().green, d)                             # k has no method yet
        @test code == 1
        @test occursin("k triples", out) && occursin("h doubles", out)
        kl = filter(l -> occursin("k triples", l), split(out, '\n'))
        @test !isempty(kl) && !any(l -> occursin("PASSED", l), kl)
        @test any(l -> occursin("PASSED", l), filter(l -> occursin("h doubles", l), split(out, '\n')))
        @test tj_clean(d)
    end

    tb_testset("a surviving mutant's evidence is not dirty", TB_NEEDS...) do
        d = tb_lane_a()
        ev = tj_ev(d, "mutate-$(tb(:slug)(ITEM_P))")
        # test_tdd_backfill.jl's "surviving mutant exits 1" leaves this file; run it only if it did not
        if !(isfile(ev) && tb_exit(ev) == "1" && occursin("SURVIVED", read(ev, String)))
            line = tb_at(d, "src/TddLane.jl", "return x + secret_body_marker")
            code, _ = tj_call(tb(:mutate), d; item = ITEM_P, src = line, from = "x + secret_body_marker", to = "secret_body_marker + x")
            @test code == 1
        end
        @test isfile(ev) && tb_exit(ev) == "1"
        h = Evidence.header(ev)
        @test h !== nothing && get(h, "dirty", "") == "false"
        @test h !== nothing && get(h, "head", "") == tj_head(d)
        @test tj_clean(d)                                                  # the real tree is clean
        v = th(:evidence_rules)(d, th(:lane_commits)(d, "main"); ledger = nothing)
        @test !any(l -> startswith(l, "E4") && occursin(basename(ev), l), v)
    end

    tb_testset("mutate --src outside src/ext exits 2; --expect outside test/ exits 2", TB_NEEDS...) do
        d = tb_lane_a()
        before = trv2_evdir(d)
        # each would survive (the item still passes), so today it costs one run and exits 1
        code, out = tj_call(tb(:mutate), d; item = ITEM_G, src = tb_at(d, "test/base_tests.jl", "@test g(1) == 2"), from = "== 2", to = "== 2 ")
        @test code == 2
        line = tb_at(d, "src/TddLane.jl", "return x + secret_body_marker")
        code, out = tj_call(tb(:mutate), d; item = ITEM_G, expect = line, from = "x + secret_body_marker", to = "secret_body_marker + x")
        @test code == 2
        @test trv2_evdir(d) == before                                      # no evidence written or changed
        @test tj_clean(d)
    end
end
