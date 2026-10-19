# Seeded by the ecosystem factory. Contract tests: the `@testitem`s tagged :contract under
# test/contracts/, run in this directory's own environment by `julia scripts/ci.jl contracts`
# (never by Pkg.test). The environment has no package name, so no `using <ThisPackage>` is
# added to a test item: each one says `using <Upstream>` itself.
using TestItemRunner
TestItemRunner.run_tests(@__DIR__; filter = ti -> :contract in ti.tags)
