# Snapshot (golden-output) tests for tibble-style printing. Goldens live in test/snapshots/show/.
#
# Every frame is rendered with `IOContext(io, :displaysize => (24, 80), :limit => true)` and no
# colour. To (re)write the goldens after an intended change, run the tests with
#
#     CHUI_UPDATE_SNAPSHOTS=1 julia --startup-file=no scripts/ci.jl test -- snapshot
#
# then review `git diff test/snapshots/` before committing. Snapshot items are tagged `:snapshot`
# and run on stable Julia only (test/runtests.jl drops them when CI_STABLE=false).
#
# Layout reference (R 4.4, tibble 3.3.0, pillar, `options(width = 60)`), e.g.
#   > print(tibble(x = c(1.23456789, NA, -1e6), s = c("a", "a very long string that goes on and on", NA)))
#   # A tibble: 3 × 2
#               x s
#           <dbl> <chr>
#   1        1.23 a
#   2       NA    a very long string that goes on and on
#   3 -1000000    <NA>
# The other R outputs relied on are quoted in the comments of src/show/format.jl,
# src/show/frame_show.jl, src/show/glimpse.jl and src/show/banner.jl.

# Helpers (`render`, `render_glimpse`, `check_snapshot`): test/show/snapshot_helpers.jl.

@testitem "snapshot: basic frame" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame
    f = Frame(x = [1.23456789, missing, -1.0e6], s = ["a", "a very long string that goes on and on", missing])
    check_snapshot("basic", render(f))
    check_snapshot("basic_narrow", render(f; w = 30))
end

@testitem "snapshot: numbers" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame
    f = Frame(
        x = [1.5, 22.25, 333.125, -4.0], y = [1.0e-10, 1.0, 1.0e10, missing],
        z = [10000000.0, 2, 3, 4], i = Int32[1, -20, 300, 4000],
        special = [NaN, Inf, -Inf, 0.0], u = UInt8[0, 1, 2, 255],
    )
    check_snapshot("numbers", render(f))
end

@testitem "snapshot: long frame" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame
    f = Frame(a = collect(1:25), b = [string(Char('a' + (i - 1) % 26)) for i in 1:25], c = [isodd(i) for i in 1:25])
    check_snapshot("long", render(f))
    check_snapshot("long_short_display", render(f; h = 10))
end

@testitem "snapshot: wide frame" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame
    f = Frame(; (Symbol("column_$i") => fill(i, 30) for i in 1:100)...)
    check_snapshot("wide", render(f))
end

@testitem "snapshot: grouped frame" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame
    f = Frame(g = ["a", "b", "a"], h = [1.0, 1.0, 2.0], x = [1, 2, 3])
    check_snapshot("grouped", render(Frame(getfield(f, :names), getfield(f, :columns), [:g, :h])))
end

@testitem "snapshot: dates, nested and object columns" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame
    using Dates
    f = Frame(
        d = [Date(2024, 1, 2), missing], t = [DateTime(2024, 1, 2, 3, 4, 5), DateTime(2024, 12, 31, 23, 59, 59, 999)],
        l = [[1, 2], Int[]], st = [(a = 1, b = "x"), (a = 2, b = "y")], o = [:sym, :other],
        any = Any[1 // 2, "text"], bin = [codeunits("abc"), codeunits("")], flag = [true, missing],
    )
    check_snapshot("nested", render(f))
end

@testitem "snapshot: strings, unicode and names" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame, AbstractColumn, column
    f = Frame(
        [Symbol("my col"), :日本, :s, :t, :u, :v],
        AbstractColumn[
            column([1.0, 2.0]), column(["日本語のテキスト", "ok"]), column(["x", "y"]),
            column([repeat("long text ", 12), "short"]), column([repeat("other text ", 10), "line\nbreak"]),
            column([1, 2]),
        ],
    )
    check_snapshot("strings", render(f))
end

@testitem "snapshot: empty and missing" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame, AbstractColumn
    check_snapshot("empty_0x0", render(Frame()))
    check_snapshot("empty_0x2", render(Frame(x = Int[], y = String[])))
    check_snapshot("empty_3x0", render(Frame(Symbol[], AbstractColumn[], Symbol[], nothing, 3)))
    check_snapshot("all_missing", render(Frame(m = [missing, missing], n = Union{Missing, Float64}[missing, missing])))
end

@testitem "snapshot: glimpse" tags = [:snapshot] begin
    include(joinpath(pkgdir(ChuiFrames), "test", "show", "snapshot_helpers.jl"))
    using ChuiFrames: Frame
    using Dates
    f = Frame(
        x = [1.23456789, missing, -1.0e6], s = ["a", "a very long string that goes on and on", missing],
        l = [[1, 2], [3], Int[]], d = [Date(2024, 1, i) for i in 1:3], n = collect(1:3),
    )
    check_snapshot("glimpse", render_glimpse(f))
    g = Frame(getfield(f, :names), getfield(f, :columns), [:n])
    check_snapshot("glimpse_grouped", render_glimpse(g; w = 40))
end
