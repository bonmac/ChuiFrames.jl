# 0.3.0: the suite's child processes must not inherit the user's session overrides.
# The hooks honour FACTORY_ALLOW_T3 / FACTORY_ALLOW_PUSH from their own environment; a caller
# running the suite with either set used to flip ~100 deny tests to allow.
# Needs the helpers from runtests.jl and test_hooks.jl (hook, blocked, bash, write_payload).
@testset "child processes do not inherit FACTORY_ALLOW_T3 / FACTORY_ALLOW_PUSH" begin
    for v in ("FACTORY_ALLOW_T3", "FACTORY_ALLOW_PUSH")
        seen = read(`sh -c "printf %s \"\${$v-unset}\""`, String)
        @test seen == "unset"
    end
    r = realpath(mktempdir())
    # no explicit env: a T3 write and a push must still be denied
    rc, _, err = hook("write_guard.sh", write_payload("$r/risk.toml"), r)
    @test rc == 2 && occursin("T3", err)
    @test blocked("write_guard.sh", write_payload("$r/.github/workflows/CI.yml"), r)
    @test blocked("bash_guard.sh", bash("git push origin feat/x"; cwd = r), r)
    # an explicit env still reaches the hook
    @test !blocked("write_guard.sh", write_payload("$r/risk.toml"), r; env = Dict("FACTORY_ALLOW_T3" => "1"))
    @test !blocked("bash_guard.sh", bash("git push origin feat/x"; cwd = r), r; env = Dict("FACTORY_ALLOW_PUSH" => "1"))
end
