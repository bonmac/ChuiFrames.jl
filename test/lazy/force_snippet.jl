# Test helper for the phase-4 forcing switches (spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §0.3): internal module-level `Ref`s, each defined in its owner's file, set only through
# `withforce`. TestItemRunner runs the test items one at a time in one process, so a switch set
# here is seen by the code under test and restored before the next item.

@testsnippet Force begin
    """
        withforce(f, pairs::Pair{<:Ref}...)

    Set each `ref => value`, run `f()`, and restore every old value (also when `f` throws).
    """
    function withforce(f, pairs::Pair{<:Ref}...)
        old = map(p -> p.first[], pairs)
        try
            foreach(p -> (p.first[] = p.second), pairs)
            return f()
        finally
            foreach((p, o) -> (p.first[] = o), pairs, old)
        end
    end
end

@testitem "withforce sets and restores Refs" tags = [:unit] setup = [Force] begin
    a = Ref(:auto)
    b = Ref(0)
    @test withforce(() -> (a[], b[]), a => :compiled, b => 4) == (:compiled, 4)
    @test (a[], b[]) == (:auto, 0)
    @test_throws ErrorException withforce(() -> error("boom"), a => :interpreter)
    @test a[] === :auto
end

@testitem "explain(; kernel) keyword: the default output has no kernel line" tags = [:unit] begin
    q = filter(c.x .> 1)(lazy((x = [1, 2, 3],)))
    plain = sprint(io -> explain(io, q))
    @test sprint(io -> explain(io, q; kernel = false)) == plain
    @test occursin("== physical plan ==", sprint(io -> explain(io, q; kernel = true)))
end
