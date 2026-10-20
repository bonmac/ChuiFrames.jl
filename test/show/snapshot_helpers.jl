# Helpers for the snapshot items in show_snapshot_tests.jl, `include`d by each item. (A
# `@testsetup` module is not used: test/runtests.jl's tag filter drops untagged setups when tags
# are selected, so `scripts/ci.jl test -- snapshot` could not find it.)

const SNAPSHOT_DIR = joinpath(pkgdir(ChuiFrames), "test", "snapshots", "show")
const UPDATE_SNAPSHOTS = get(ENV, "CHUI_UPDATE_SNAPSHOTS", "") in ("1", "true")

render(f; w = 80, h = 24) =
    sprint((io, x) -> show(IOContext(io, :displaysize => (h, w), :limit => true), MIME"text/plain"(), x), f)
render_glimpse(f; w = 80) = sprint(ChuiFrames.glimpse, f; context = (:displaysize => (24, w)))

"Compare `out` with the golden `name.txt` (written first when CHUI_UPDATE_SNAPSHOTS=1)."
function check_snapshot(name::AbstractString, out::AbstractString)
    path = joinpath(SNAPSHOT_DIR, name * ".txt")
    if UPDATE_SNAPSHOTS
        mkpath(SNAPSHOT_DIR)
        write(path, out * "\n")
        @info "snapshot written" path
    end
    @test isfile(path)
    isfile(path) || return nothing
    golden = chomp(read(path, String))
    golden == out || @info "snapshot mismatch: $name" expected = golden got = out
    @test golden == out
    return nothing
end
