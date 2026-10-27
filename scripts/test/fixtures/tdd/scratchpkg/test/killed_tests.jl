# Sleeps only when selected by name, so an unfiltered run does not hang. The fixture run kills the
# test process with SIGTERM while it sleeps (see ../../README.md).
@testitem "killed" begin
    "item=killed" in ARGS && sleep(3600)
    @test true
end
