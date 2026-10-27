# Topology (a) helpers of the tdd_boundary tests (factory 0.3.0, plan Task 8), moved out of
# test_hooks_tdd.jl for its 400-line budget. Included by test_hooks_tdd.jl before its testsets; it
# uses that file's tb_git, tb_env and TB_GIT. The topology is described in test_hooks_tdd.jl's header.

# ---- topology (a) ----
"A git repo at `d` (created) with one commit on main; `links` maps relative path => symlink target."
function tb_repo(d, files; links = Dict{String, String}())
    mkpath(d)
    tb_git(d, "init", "-q", "-b", "main")
    for (k, v) in ("user.name" => "test", "user.email" => "t@example.com", "commit.gpgsign" => "false")
        tb_git(d, "config", k, v)
    end
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    for (rel, target) in links
        symlink(target, joinpath(d, rel))
    end
    tb_git(d, "add", "-A")
    tb_git(d, "commit", "-q", "-m", "init")
    return d
end
tb_pkg_files(name) = Dict(
    ".gitignore" => ".lanes/\n.worktrees/\n", "Project.toml" => "name = \"$name\"\n",
    "src/$name.jl" => "module $name\nf(x) = x\nend\n", "ext/$(name)Ext.jl" => "module $(name)Ext end\n",
    "test/runtests.jl" => "using Test\n", "test/Project.toml" => "[deps]\n",
    "test/t.jl" => "@testitem \"f\" begin\n    @test true\nend\n", "docs/src/index.md" => "# $name\n",
    "changelog.d/x.md" => "- x\n",
)
function tb_write!(d, files)
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    return
end
"Session root S (coordinator stand-in) with S/Pkg.jl + lane worktree lane1, S/Pkg2.jl + lane1, a scratch HOME."
function tb_topo()
    S = tb_repo(
        joinpath(realpath(mktempdir()), "coord"), Dict(
            ".gitignore" => "Pkg.jl/\nPkg2.jl/\nFx*/\n.lanes/\n",
            "docs/superpowers/specs/s.md" => "# spec\n", "contracts/c.md" => "c\n", "adr/0001-x.md" => "adr\n", "HANDOFF.md" => "h\n"
        )
    )
    pkg = tb_repo(joinpath(S, "Pkg.jl"), tb_pkg_files("P"); links = Dict("test/lnk" => "../src"))
    pkg2 = tb_repo(joinpath(S, "Pkg2.jl"), tb_pkg_files("Q"))
    tb_git(pkg, "worktree", "add", "-q", "-b", "lane1", ".worktrees/lane1")
    tb_git(pkg2, "worktree", "add", "-q", "-b", "lane1", ".worktrees/lane1")
    lane, lane2 = joinpath(pkg, ".worktrees", "lane1"), joinpath(pkg2, ".worktrees", "lane1")
    tb_write!(
        lane, Dict(
            ".lanes/evidence/red-abc1234.txt" => "red\n", ".lanes/evidence/green-abc1234.txt" => "green\n",
            ".lanes/evidence/mutate-f-0a1b2c3d-abc1234.txt" => "m\n", ".lanes/evidence/mutexp-f-0a1b2c3d-abc1234.txt" => "m\n",
            ".lanes/scratch/mutate/src/P.jl" => "module P end\n", ".lanes/reports/r.md" => "report\n"
        )
    )
    home = realpath(mktempdir())
    tb_write!(home, Dict(".claude/projects/-coord/abc.jsonl" => "{}\n", ".julia/packages/P/xyz/src/P.jl" => "module P end\n"))
    return (; S, pkg, lane, pkg2, lane2, home)
end
"Build fixture `name` (fixtures/tdd/git/<name>.sh) at S/<dir>, give it a non-role user, return its path."
function tb_fixture(t, name, dir)
    d = joinpath(t.S, dir)
    sh(Cmd(addenv(`sh $(joinpath(TB_GIT, name)) $d`, tb_env(t)...)))
    tb_git(d, "config", "user.name", "test")
    tb_git(d, "config", "user.email", "t@example.com")
    return d
end
