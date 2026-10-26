# Unit tests of joins in lazy plans (phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §1.2-§1.4): the plan tree, names resolved once, lowering through `collect`, replay, filter
# pushdown (fires and does not fire, §1.3), per-side projection, and explain's decision.

@testsnippet LazyJoin begin
    using Tables
    const ⨟ = ChuiFrames.Upstream.:⨟
    const FORCES = (:auto, :broadcast_x, :broadcast_y, :partitioned_x, :partitioned_y)
    outcome(f) = try
        (:ok, f())
    catch err
        (:err, typeof(err), sprint(showerror, err))
    end
    sametypes(a, b) = [eltype(c) for c in a.columns] == [eltype(c) for c in b.columns]
    "lazy (collect) == eager under every forced shape, morsel size and threading; types too."
    function lazy_matches(build, x; morsels = (1, 3, 64), kw...)
        e = outcome(() -> build(x))
        ok = true
        for v in FORCES, m in morsels, th in (false, true)
            l = withforce(() -> outcome(() -> collect(build(lazy(x)); morsel = m, threads = th)), ChuiFrames._FORCE_JOIN => v)
            good = if e[1] === :err
                l[1] === :err && l[2] === e[2] && l[3] == e[3]
            else
                l[1] === :ok && isequal(l[2], e[2]) && sametypes(l[2], e[2])
            end
            good || @info "lazy != eager" force = v morsel = m threads = th eager = e lazy = l
            ok &= good
        end
        return ok
    end
    fired(q) = last(ChuiFrames.optimize_plan(q.plan)).fired
    pushed(q) = any(r -> occursin("below join(", r), fired(q))
end

@testitem "lazy join: lazy == eager for every kind and shape" tags = [:unit] setup = [Force, LazyJoin] begin
    x = Frame(k = Union{Missing, Float64}[2.0, 1.0, NaN, missing, -0.0, 2.0, 7.0], v = ["a", "b", "c", "d", "e", "f", "g"])
    y = Frame(k = Union{Missing, Float64}[2.0, 0.0, NaN, 2.0, 5.0, missing], w = [10, 20, 30, 40, 50, 60], v = [1, 2, 3, 4, 5, 6])
    for verb in (inner_join, left_join, right_join, full_join), keep in (false, true), m in (:all, :first, :last), na in (:na, :never)
        @test lazy_matches(t -> verb(y; by = :k, keep, multiple = m, na_matches = na)(t), x; morsels = (1, 4))
    end
    for verb in (semi_join, anti_join), na in (:na, :never)
        @test lazy_matches(t -> verb(y; by = :k, na_matches = na)(t), x)
    end
    @test lazy_matches(t -> nest_join(y; by = :k)(t), x)
    @test lazy_matches(t -> nest_join(y; by = :k, keep = true, na_matches = :never)(t), x)
    @test lazy_matches(t -> cross_join(y)(t), x)
    # errors: lazy raises eager's exception (collect replays eagerly), message included
    @test lazy_matches(t -> inner_join(y; by = :k, unmatched = :error)(t), x)
    @test lazy_matches(t -> left_join(y; by = :k, multiple = :error)(t), x)
    @test lazy_matches(t -> nest_join(y; by = :k, unmatched = :error)(t), x)
    # steps above and below the join, and a lazy y
    @test lazy_matches(t -> (filter(c.v .!= "c") ⨟ left_join(lazy(y) |> filter(c.w .> 10); by = :k) ⨟ mutate(z = c.w .+ 1))(t), x)
    @test lazy_matches(t -> (inner_join(y; by = :k) ⨟ head(2))(t), x)
    @test lazy_matches(t -> (inner_join(y; by = :k) ⨟ group_by(:v_x) ⨟ summarise(n = n_rows()))(t), x)
    # a grouped x keeps its groups; a join of joins
    @test lazy_matches(t -> left_join(y; by = :k)(t), group_by(:v)(x))
    z = Frame(w = [10, 40, 99], u = ["p", "q", "r"])
    @test lazy_matches(t -> (inner_join(y; by = :k) ⨟ left_join(z; by = :w))(t), x)
    @test lazy_matches(t -> left_join(lazy(y) |> inner_join(z; by = :w); by = :k)(t), x)
end

@testitem "lazy join: the error precedence through collect (MAJOR-3)" tags = [:unit] setup = [Force, LazyJoin] begin
    y = Frame(k = [1, 1])
    @test lazy_matches(t -> inner_join(y; by = :k, unmatched = :error, multiple = :error)(t), Frame(k = [2, 1]))
    @test lazy_matches(t -> inner_join(y; by = :k, unmatched = :error, multiple = :error)(t), Frame(k = [1, 2]))
    @test lazy_matches(t -> inner_join(Frame(k = [1, 3]); by = :k, unmatched = :error)(t), Frame(k = [1]))
end

@testitem "lazy join: the plan is a tree (JoinNode, ==, fmap, node_schema)" tags = [:unit] setup = [LazyJoin] begin
    CF = ChuiFrames
    x = Frame(k = [1, 2], v = [1.0, 2.0])
    y = Frame(k = [2, 3], w = ["a", "b"])
    q = left_join(y; by = :k)(lazy(x))
    j = q.plan
    @test j isa CF.JoinNode
    @test j.names isa CF.JoinNames && j.names.compare == Type[Int]
    @test j == CF.JoinNode(j.left, j.right, j.spec, j.names)
    @test CF.UP.cata(n -> n isa CF.JoinNode ? 1 + n.left + n.right : n isa CF.StepNode ? n.child : 0, j) == 1
    sch = CF.node_schema(j)
    @test sch[1] == [:k, :v, :w]
    @test sch[2] == Type[Int, Float64, Union{Missing, eltype(CF.getcol(y, :w))}]
    # a mutate makes a side's types non-static: no schema, no compare type
    q2 = left_join(y; by = :k)(mutate(z = c.v .* 2)(lazy(x)))
    @test q2.plan.names.compare === nothing && CF.node_schema(q2.plan) === nothing
    # the static key check runs when the node is built
    @test_throws ArgumentError inner_join(Frame(k = ["a"]); by = :k)(lazy(x))
    @test_throws ArgumentError inner_join(Frame(k = [1], var"##chui_a" = [1]); by = :k)(lazy(x))
    # show and the tree printing
    @test occursin("join(left; by = [:k])", sprint(show, q))
    txt = sprint(show, MIME("text/plain"), q)
    @test occursin("├─ x:", txt) && occursin("└─ y:", txt)
end

@testitem "lazy join: names are resolved once (natural-join @info, nest_join @warn)" tags = [:unit] setup = [Force, LazyJoin] begin
    x = Frame(k = [1, 2], y = [5, 6])
    yy = Frame(k = [2, 3], w = [7, 8])
    q = @test_logs (:info, "Joining with by = [:k]") inner_join(yy)(lazy(x))
    @test_logs collect(q)                       # nothing logged again
    @test_logs optimize(q)
    @test_logs sprint(explain, q)
    @test isequal(collect(q), inner_join(yy; by = :k)(x))
    qn = @test_logs (:warn, r"replaces x's column :y") nest_join(yy; by = :k)(lazy(x))
    @test_logs collect(qn)
    # a lazy failure replays eagerly without logging again
    qe = @test_logs (:info, "Joining with by = [:k]") inner_join(yy; unmatched = :error)(lazy(x))
    logs, err = Test.collect_test_logs() do
        try
            collect(qe)
            nothing
        catch e
            e
        end
    end
    @test err isa ArgumentError
    @test isempty(logs)
    # a side whose names cannot be computed without running it (its empty-frame probe throws:
    # `maximum` of no rows) is resolved, and logged, at collect, once
    ys = lazy(yy) |> mutate(d = c.w .- maximum(c.w))
    qs = @test_logs inner_join(ys)(lazy(x))
    @test qs.plan.names === nothing
    r = @test_logs (:info, "Joining with by = [:k]") collect(qs)
    @test isequal(r, inner_join(mutate(d = c.w .- maximum(c.w))(yy); by = :k)(x))
    @test occursin("by = nothing (resolved at collect)", sprint(explain, qs))
end

@testitem "lazy join: filter pushdown fires (spec §1.3)" tags = [:unit] setup = [Force, LazyJoin] begin
    x = Frame(k = [1, 2, 3, 2], a = [1.0, 2.0, 3.0, 4.0])
    y = Frame(k = [2, 3, 3], b = [10, 20, 30])
    for (verb, p) in (
            (inner_join, filter(c.a .> 1.5)), (inner_join, filter(c.b .> 10)), (left_join, filter(c.a .> 1.5)),
            (right_join, filter(c.b .> 10)), (semi_join, filter(c.a .> 1.5)), (anti_join, filter(c.k .> 1)),
            (inner_join, filter(c.k .> 1)), (left_join, filter(c.k .== 2)),
        )
        b = t -> (verb(y; by = :k) ⨟ p)(t)
        @test pushed(b(lazy(x)))
        @test lazy_matches(b, x)
    end
    @test pushed(filter(c.a .> 1.5)(nest_join(y; by = :k)(lazy(x))))
    @test pushed(filter(c.b .> 10)(cross_join(y)(lazy(x))))
end

@testitem "lazy join: filter pushdown does not fire where it must not (spec §1.3)" tags = [:unit] setup = [Force, LazyJoin] begin
    x = Frame(k = [1, 2, 3, 2], a = [1.0, 2.0, 3.0, 4.0])
    y = Frame(k = [2, 3, 3], b = [10, 20, 30])
    cases = Any[
        # multiple = :first/:last/:any with a y filter
        t -> (inner_join(y; by = :k, multiple = :first) ⨟ filter(c.b .> 20))(t),
        t -> (inner_join(y; by = :k, multiple = :last) ⨟ filter(c.b .> 10))(t),
        t -> (inner_join(y; by = :k, multiple = :any) ⨟ filter(c.b .> 20))(t),
        # multiple = :error with an x filter and with a y filter
        t -> (inner_join(y; by = :k, multiple = :error) ⨟ filter(c.a .> 1.5))(t),
        t -> (inner_join(y; by = :k, multiple = :error) ⨟ filter(c.b .> 10))(t),
        # unmatched = :error: inner (x and y filter), left (y filter), right (x filter)
        t -> (inner_join(y; by = :k, unmatched = :error) ⨟ filter(c.a .> 1.5))(t),
        t -> (inner_join(y; by = :k, unmatched = :error) ⨟ filter(c.b .> 10))(t),
        t -> (left_join(y; by = :k, unmatched = :error) ⨟ filter(c.b .> 10))(t),
        t -> (right_join(y; by = :k, unmatched = :error) ⨟ filter(c.a .> 1.5))(t),
        # a full join with any filter; key predicates on right/full
        t -> (full_join(y; by = :k) ⨟ filter(c.a .> 1.5))(t),
        t -> (right_join(y; by = :k) ⨟ filter(c.k .> 1))(t),
        t -> (full_join(y; by = :k) ⨟ filter(c.k .> 1))(t),
        # left: never to y; right: never to x
        t -> (left_join(y; by = :k) ⨟ filter(c.b .> 10))(t),
        t -> (right_join(y; by = :k) ⨟ filter(c.a .> 1.5))(t),
        # a non-R-total predicate
        t -> (inner_join(y; by = :k) ⨟ filter(sqrt.(c.a) .> 1.0))(t),
        # nest_join: a filter on the nested column, and any filter under unmatched = :error
        t -> (nest_join(y; by = :k) ⨟ filter(map(f -> f.nrow > 0, c.y)))(t),
        t -> (nest_join(y; by = :k, unmatched = :error) ⨟ filter(c.a .> 1.5))(t),
        # a nest_join whose name is x's key column (m1): the column is the nested one
        t -> (nest_join(y; by = :k, name = :k) ⨟ filter(map(f -> f.nrow > 0, c.k)))(t),
    ]
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    for b in cases
        @test !pushed(quiet(() -> b(lazy(x))))
        @test quiet(() -> lazy_matches(b, x; morsels = (1, 3)))
    end
    # signbit on 0.0 vs -0.0: a key predicate is never copied to y; lazy == eager
    xs = Frame(k = [0.0, 1.0])
    ys = Frame(k = [-0.0], w = [1])
    @test lazy_matches(t -> (inner_join(ys; by = :k) ⨟ filter(signbit.(c.k)))(t), xs)
    @test lazy_matches(t -> (inner_join(ys; by = :k) ⨟ filter(.!signbit.(c.k)))(t), xs)
    # a key predicate when a key type is not static (MAJOR-1): not pushed
    g(a) = a > 1 ? 1.5 : 1
    b = t -> (mutate(:k => g.(c.a)) ⨟ inner_join(Frame(k = [1.5, 1.0]); by = :k) ⨟ filter(c.k .> 1.0))(t)
    @test !pushed(b(lazy(x)))
    @test lazy_matches(b, x)
end

@testitem "lazy join: projection keeps keys and clashing columns per side (M3)" tags = [:unit] setup = [Force, LazyJoin] begin
    x = Frame(k = [1, 2], v = [1, 2], extra = ["p", "q"])
    y = Frame(k = [1, 3], v = [10, 30], other = [0.5, 1.5])
    # eager throws (v is v_x / v_y); lazy keeps y.v and throws too
    @test lazy_matches(t -> (inner_join(y; by = :k) ⨟ select(:v))(t), x)
    @test lazy_matches(t -> (inner_join(y; by = :k) ⨟ select(:v_x, :other))(t), x)
    q = (inner_join(y; by = :k) ⨟ select(:v_y))(lazy(x))
    plan = optimize(q).plan
    j = plan.child
    @test j isa ChuiFrames.JoinNode
    @test j.left.select == [:k, :v]
    @test j.right.select == [:k, :v]
    # the names never change under projection
    @test j.names.outnames == [:k, :v_x, :extra, :v_y, :other]
    @test lazy_matches(t -> (left_join(y; by = :k) ⨟ summarise(s = sum(c.k)))(t), x)
end

@testitem "lazy join: explain and collect agree on exact inputs (m4)" tags = [:unit] setup = [Force, LazyJoin] begin
    small = Frame(k = [1, 2], w = [1, 2])
    big = Frame(k = collect(1:50), v = collect(1:50))
    for (x, y) in ((small, big), (big, small))
        q = inner_join(y; by = :k)(lazy(x))
        txt = sprint(explain, q)
        e = ChuiFrames.join_decision(q.plan.spec, ChuiFrames._plan_estimate(q.plan.left), ChuiFrames._plan_estimate(q.plan.right))
        @test occursin("strategy: broadcast, build $(e[2])", txt)
        low = ChuiFrames._lower_joins(optimize(q).plan)
        steps, _ = ChuiFrames._chain(low)
        probe = only(filter(s -> s isa ChuiFrames.ProbeStep, steps))
        @test probe.side === e[2]
    end
    # forced: explain says so
    q = inner_join(big; by = :k)(lazy(small))
    @test occursin("forced by _FORCE_JOIN", withforce(() -> sprint(explain, q), ChuiFrames._FORCE_JOIN => :partitioned_x))
    @test occursin("partitioned into 2^4", withforce(() -> sprint(explain, q), ChuiFrames._FORCE_JOIN => :partitioned_x))
    @test occursin("not rendered (the stage holds a join probe)", withforce(() -> sprint(explain, q), ChuiFrames._FORCE_JOIN => :broadcast_y))
    # code_lowered on a join plan does not throw
    @test occursin("nothing to render", sprint(code_lowered, q))
end

@testitem "lazy join: a mutated key whose type differs per morsel (MAJOR-1)" tags = [:unit] setup = [Force, LazyJoin] begin
    f(a) = a > 1 ? 1.5 : 1
    b = t -> (mutate(:k => f.(c.a)) ⨟ inner_join(Frame(k = [1.5]); by = :k))(t)
    x = Frame(a = [1, 2])
    e = outcome(() -> b(x))
    @info "MAJOR-1 case: eager outcome" e
    @test lazy_matches(b, x; morsels = 1:7)
end
