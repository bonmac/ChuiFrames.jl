# tdd.jl fixtures

Measured inputs for the `tdd.jl` classifier and the history rules (plan
`<root>/docs/superpowers/plans/2026-10-26-factory-test-writer.md` Task 1; spec §3.3, §3.4). Everything here is
data, not tests. Do not edit an output file by hand; regenerate it.

## `scratchpkg/`: the scratch package (TddScratch)

The critic's `TddScratch` (`<root>/.lanes/scratch/tw-critic/TddScratch`), with `[compat] julia` added
(the factory's seeded-environment check needs it) and four new cases. One `@testitem` per case:

| Case (`item=`) | File in `scratchpkg/test/` | What fails |
|---|---|---|
| `assert` | `items_tests.jl` | `@test g(1) == 3`: a wrong value |
| `stub in test` | `items_tests.jl` | `f(1)` inside `@test` on the stub `function f end`: MethodError |
| `stub outside test` | `items_tests.jl` | the same call outside `@test`: `LoadError: MethodError` |
| `typo` | `items_tests.jl` | `gg(1)` inside `@test`: UndefVarError |
| `typo outside` | `items_tests.jl` | `gg(1)` outside `@test`: `LoadError: UndefVarError` |
| `helper` | `items_tests.jl` | an `@assert` inside `helpers.jl`: AssertionError |
| `passes` | `items_tests.jl` | nothing |
| `throws wrong` | `items_tests.jl` | `@test_throws ArgumentError` gets MethodError |
| `throws typo` | `items_tests.jl` | `@test_throws ArgumentError` gets UndefVarError |
| `new method on existing g` | `items_tests.jl` | `g("a")`: `MethodError: no method matching +(::String, ::Int64)` |
| `nested` | `items_tests.jl` | a failing `@test` in an inner `@testset "inner"`: the header names `inner` |
| `parse error` (new) | `parse_tests.jl` | a syntax error in the item body: `LoadError: ParseError:` |
| `setup module` (new) | `setup_tests.jl` | its `setup = [BrokenSetup]` module throws UndefVarError at load |
| `none` (new) | none | `item=nosuch` matches nothing: exit 0, `Total 0` |
| `killed` (new) | `killed_tests.jl` | the test process gets SIGTERM while the item sleeps |
| `precompile fail` (new; run as `item=assert`) | `items_tests.jl` | made in a scratch copy of scratchpkg with its `scripts/test/fixtures/tdd/scratchpkg/src/TddScratch.jl` line 4 changed to `g(x) = x + 1)`, run with `item=assert`: the package fails to precompile, so `assert` errors with `Got exception outside of a @test` and 1.13's `The following 1 package failed to precompile:` or 1.10's `Failed to precompile TddScratch [...]` (outputs `precompile-fail-1.13.txt`, `precompile-fail-1.10.txt`) |

| `unexpected pass` (review) | `review_tests.jl` | `@test_broken 1 == 1` holds: `Error During Test` with `Unexpected Pass` |
| `letctx` (review) | `review_tests.jl` | `undefined_fnn(v)` inside `@testset let v = 1`: UndefVarError; 1.13 prints `Context: v = 1` between `Expression:` and the exception, 1.10 does not |

The review cases were added to the committed scratchpkg as their own file, `review_tests.jl`, on
2026-10-26 (Julia 1.13.2 and 1.10.12, the commands below). A new file moves no line of the other
files, and every other output was made with an `item=` filter that does not select these items, so
the other fixtures stay valid.

The `stub outside test` and `typo outside` cases do not break the package or the file: each fails only
its own item, with `Got exception outside of a @test` and a `LoadError: ` prefix. One source tree serves
every case, so there are no variant directories or env switches. The new cases live in their own files
so a parse error cannot touch the critic's items (measured: other items still run).

`killed` sleeps only when `item=killed` is in `ARGS`, so an unfiltered run does not hang. `test/runtests.jl`
is the critic's filter, verbatim (an empty `ARGS` runs everything).

`Manifest*.toml` is not committed; Pkg.test writes a `Manifest.toml` holding only TddScratch on the first
run, and `/scripts/test/fixtures/tdd/scratchpkg/Manifest*.toml` in the template's `.gitignore` ignores it.

## `<case>-1.13.txt`, `<case>-1.10.txt`: the outputs

Slug = the case name with spaces replaced by `-` (`none` is the `item=nosuch` run). Each file holds:

1. a header line `# julia <version>, TestItemRunner <version>, command: ...`;
2. for `killed`, a second `# killed: ...` line;
3. the run's combined stdout and stderr, verbatim;
4. a last line `# exit status: <n>` (the outer `julia` process).

Measured on 2026-10-26: Julia 1.13.2 (`julia`) and 1.10.12 (`julia +lts`), TestItemRunner 1.3.2, Test
1.11.0 (1.13), offline. Each command ran from inside `scratchpkg/`:

```sh
JULIA_PKG_OFFLINE=true julia       --project=. -e 'using Pkg; Pkg.test(test_args=ARGS)' -- "item=<case>"
JULIA_PKG_OFFLINE=true julia +lts  --project=. -e 'using Pkg; Pkg.test(test_args=ARGS)' -- "item=<case>"
```

No run was bounded by an outer timer (none needed one); timings in the files are from a loaded machine and
mean nothing.

**`killed`:** the run was started in the background. Once `Running tests` appeared in its output, the driver
waited 45 s (the item was then in `sleep(3600)`). It found the test process, the child `julia` whose
command line includes `scratchpkg/test/runtests.jl` (`pgrep -f`), and sent it `kill -TERM`, so that
process's termsignal is 15. Pkg in the outer process printed
`ERROR: Package TddScratch errored during testing (received signal: TERM)` and exited 1 with termsignal 0.
The output has no failure header and no `Test Summary:`. A classifier that only sees the outer process
therefore detects this case by the missing `Test Summary:` (spec §3.3), not by `termsignal ≠ 0`.
`termsignal ≠ 0` applies when the process tdd.jl itself starts is signalled.

**Paths in the outputs are masked.** The headers and stacktraces carried the absolute path the package had
when the files were made (a machine-local worktree path; for `precompile fail`, the scratch copy's path).
That prefix is replaced by the placeholder `<PKG>` (the package root, i.e. `scratchpkg`), and the
home-directory prefix of `.julia/compiled/...` by `~/`, so a header reads
`assert: Test Failed at <PKG>/test/items_tests.jl:2`. Nothing else in the files was changed.

The parts the classifier needs are the path suffixes (`<PKG>/test/<file>.jl:<line>`). A test that maps
headers to `@testitem` spans replaces `<PKG>` with the fixture's current `scratchpkg` path
(`TDD_RECORDED` in `test_tdd.jl`), or matches on the suffix after it. Other absolute paths (`~/.julia/...`,
`/private/var/folders/.../jl_*`) are incidental and differ per run.

**Measured facts the classifier relies on** (both versions, every file):

- the header regex `^(.+): (Test Failed|Error During Test) at (.+):(\d+)$` matches every failure header and
  no other line: one header in each failing file, none in `passes`, `none` and `killed`;
- the header line number is the line of the failing call in the item's file (1-based, inside the item's
  span; for `setup module` it is the item's `@test`, line 6, not the setup module);
- `nested` names the inner testset (`inner:`), not the item;
- 1.10 prints `UndefVarError: \`gg\` not defined`, 1.13 adds ` in \`Main.var"##143"\`` plus a
  `Suggestion:` line; 1.10 adds blank lines after some blocks. Headers are identical.

## `h5/`: parse-level pairs for H5 (stubs only declare)

Parent/child pairs (`p<n>.jl` before, `c<n>.jl` after), copied verbatim from `<root>/.lanes/scratch/tw-critic4/`:

- `p2`/`c2`: `export` and `@compat public` grow, plus `function g end`/`function h end`;
- `p3`/`c3`, `p5`/`c5`: deletions;
- `p4`/`c4`: a stub above a documented method;
- `p6`/`c6`: a stub above an undocumented method;
- `parent.jl`/`child.jl`: exports inside the module block, with an `include` and a documented stub.

`names-p.jl`/`names-c.jl`: `names-p.jl` holds three verbatim lines of `ChuiCore.jl/src/names.jl` (lines 7,
10, 13 on 2026-10-26) inside `module M ... end`. `names-c.jl` appends `, newname` to the second line and adds
`function newname end`.

## `git/`: history scenarios

POSIX `sh` scripts. Each builds a scratch repo in `$1` (default: a new `mktemp -d` directory) with identities
given per command (`git -c user.name=... -c user.email=...`, never the global config). Each prints the repo
path and then `git log` as `hash|author|committer|subject`, with the changed files:

| Script | What it makes |
|---|---|
| `amend.sh` | an implementer-authored HEAD, then `git add <test file> && git commit --amend --no-edit` by the implementer: the author is still the implementer, and the commit now holds both the scratch repo's source file and its test file |
| `C-HEAD.sh` | a test-writer red HEAD, then the implementer runs `git commit -C HEAD` on a test change: authored by `test-writer`, committed by `implementer` |
| `amend-author.sh` | an implementer HEAD amended by the implementer with `--author "test-writer <test-writer@factory.invalid>"`: authored by `test-writer`, committed by `implementer`, holding `src/` and `test/` |
| `C-reset-author.sh` | an implementer green commit, then `git commit --allow-empty -C <green> --reset-author` under the test-writer identity: author and committer are `test-writer`, and the subject (`feat: f adds one`) and the `TDD: green` trailer are the green commit's |
