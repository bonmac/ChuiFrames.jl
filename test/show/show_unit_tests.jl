# Unit tests for tibble-style printing (src/show/): the number formatter, truncation, type
# labels, width fitting, glimpse and the name-conflict banner stand-in (ADR-0014).

@testitem "show: numbers use 3 significant digits, aligned on the decimal point" tags = [:unit] begin
    using ChuiFrames: num_cells
    # R: tibble(x = c(1.5, 22.25, 333.125, -4)) prints 1.5 / 22.2 / 333. / -4
    @test num_cells([1.5, 22.25, 333.125, -4.0]) == ["  1.5", " 22.2", "333. ", " -4  "]
    # R: tibble(x = c(1.23456789, NA, -1e6)) prints 1.23 / NA / -1000000
    @test num_cells([1.23456789, missing, -1.0e6]) == ["       1.23", " missing   ", "-1000000   "]
    # R: NaN / Inf / -Inf / 0.00123 / 123457.
    @test num_cells([NaN, Inf, -Inf, 0.001234, 123456.7]) ==
        ["   NaN      ", "   Inf      ", "  -Inf      ", "     0.00123", "123457.     "]
    @test num_cells([1, 22, -333]) == ["   1", "  22", "-333"]
    @test num_cells(Union{Missing, Int}[1, missing]) == ["      1", "missing"]
    @test num_cells([0.1 + 0.2, 1 / 3]) == ["0.3  ", "0.333"]
    @test num_cells(Float32[0.5, 2]) == ["0.5", "2  "]
    @test num_cells(Float64[]) == String[]
    @test num_cells([missing, missing]) == ["missing", "missing"]
end

@testitem "show: wide-ranging columns switch to scientific notation" tags = [:unit] begin
    using ChuiFrames: num_cells
    # R: tibble(y = c(1e-10, 1, 1e10, NA)) prints 1e-10 / 1e+ 0 / 1e+10 / NA
    @test num_cells([1.0e-10, 1.0, 1.0e10, missing]) == ["  1e-10", "  1e+ 0", "  1e+10", "missing"]
    @test num_cells([1.5e20, -2.25e-3]) == [" 1.5 e+20", "-2.25e- 3"]
    @test num_cells([1.0e300]) == ["1e+300"]
    # integer-valued floats up to 13 characters stay fixed (R: 123456789012 and 1)
    @test num_cells([123456789012.0, 1.0]) == ["123456789012", "           1"]
end

@testitem "show: truncation and padding use display width" tags = [:unit] begin
    using ChuiFrames: truncate_text, pad_right, pad_left
    @test truncate_text("abcdef", 6) == "abcdef"
    @test truncate_text("abcdefg", 6) == "abcde…"
    @test truncate_text("日本語のテキスト", 7) == "日本語…"          # wide characters count 2
    @test textwidth(truncate_text("日本語のテキスト", 6)) <= 6
    @test truncate_text("abc", 1) == "…"
    @test pad_right("日本", 6) == "日本  "
    @test pad_left("ab", 4) == "  ab"
end

@testitem "show: type labels per column kind" tags = [:unit] begin
    using ChuiFrames: type_sum, column, StructColumn, DictColumn
    using Dates
    @test type_sum(column([1, 2])) == "<i64>"
    @test type_sum(column(Int32[1])) == "<i32>"
    @test type_sum(column(UInt8[1])) == "<u8>"
    @test type_sum(column([1.0])) == "<f64>"
    @test type_sum(column(Union{Missing, Float64}[1.0])) == "<f64?>"   # nullable, no missing
    @test type_sum(column(Float32[1])) == "<f32>"
    @test type_sum(column([true])) == "<bool>"
    @test type_sum(column(["a"])) == "<str>"
    @test type_sum(column(["a", missing])) == "<str?>"
    @test type_sum(column([codeunits("ab")])) == "<binary>"
    @test type_sum(column([Date(2020)])) == "<date>"
    @test type_sum(column([DateTime(2020)])) == "<dttm>"
    @test type_sum(column([[1, 2], Int[]])) == "<list[i64]>"
    @test type_sum(column([(a = 1, b = "x")])) == "<struct[2]>"
    @test type_sum(column([:a])) == "<Symbol>"
    @test type_sum(column(Any[1, "x"])) == "<any>"
    @test type_sum(column([missing, missing])) == "<missing>"
    @test type_sum(DictColumn(UInt8[1, 2, 1], column(["a", "b"]))) == "<dict[str]>"
end

@testitem "show: cell text per element" tags = [:unit] begin
    using ChuiFrames: cell_text, column
    using Dates
    @test cell_text("a\nb") == "a\\nb"          # escaped, so a cell stays on one line
    @test cell_text("say \"hi\"") == "say \"hi\""
    @test cell_text(true) == "true"
    @test cell_text(Date(2024, 1, 2)) == "2024-01-02"
    @test cell_text(DateTime(2024, 1, 2, 3, 4, 5)) == "2024-01-02T03:04:05"
    @test cell_text(column([[1, 2]])[1]) == "<i64 [2]>"
    @test cell_text(column([["a", "b", "c"]])[1]) == "<str [3]>"
    @test cell_text([1.0 2.0; 3.0 4.0]) == "<f64 [2×2]>"
    @test cell_text(column([codeunits("abc")])[1]) == "<3 bytes>"
    @test cell_text((a = 1, b = "x")) == "(a = 1, b = \"x\")"
    @test cell_text(:sym) == ":sym"
end

@testitem "show: column header names" tags = [:unit] begin
    using ChuiFrames: header_text
    @test header_text(:x) == "x"
    @test header_text(:日本) == "日本"
    @test header_text(Symbol("my col")) == "var\"my col\""
    @test header_text(Symbol("a\"b")) == "var\"a\\\"b\""
end

@testitem "show: width fitting keeps a prefix of columns at minimum width, then widens" tags = [:unit] begin
    using ChuiFrames: fit_widths
    # ideal and minimum widths; available width 20 with one space before every column
    @test fit_widths([5, 5], [5, 5], 20) == [5, 5]
    @test fit_widths([5, 5, 5, 5], [5, 5, 5, 5], 20) == [5, 5, 5]          # 3 * (1 + 5) = 18
    @test fit_widths([40, 3], [15, 3], 30) == [25, 3]                       # shrink the string column
    @test fit_widths([40, 3], [15, 3], 100) == [40, 3]
    @test fit_widths([30], [30], 10) == Int[]                               # nothing fits
    @test fit_widths(Int[], Int[], 10) == Int[]
end

@testitem "show: frame printing basics" tags = [:unit] begin
    using ChuiFrames: Frame
    render(f; w = 80, h = 24, limit = true) =
        sprint((io, x) -> show(IOContext(io, :displaysize => (h, w), :limit => limit), MIME"text/plain"(), x), f)
    f = Frame(x = [1.5, missing, 3.0], s = ["a", "b", missing])
    out = render(f)
    lines = split(out, '\n')
    @test lines[1] == "# A Frame: 3 × 2"
    @test occursin("<f64?>", lines[3]) && occursin("<str?>", lines[3])
    @test occursin("missing", out)
    @test !occursin('\e', out)
    # long frames: 10 rows when more than 20, else all (tibble)
    long = Frame(a = collect(1:25))
    @test occursin("# ℹ 15 more rows", render(long))
    @test count(==('\n'), render(Frame(a = collect(1:20)))) == 1 + 2 + 20 - 1
    @test !occursin("more rows", render(long; limit = false))
    # the height of the display is respected
    @test count(==('\n'), render(long; h = 10)) <= 9
    # the width of the display is respected
    wide = Frame(; (Symbol("column_$i") => [i] for i in 1:20)...)
    @test all(l -> textwidth(l) <= 60, split(render(wide; w = 60), '\n'))
    @test occursin("# ℹ 14 more variables: column_7 <i64>", render(wide; w = 60))
    @test !occursin("more variables", render(wide; limit = false))
    # singular footers
    @test endswith(render(Frame(a = [1], b = [2]); w = 10), "\n# ℹ 1 more variable: b <i64>")
    # compact two-argument show
    @test sprint(show, f) == "Frame: 3 × 2 [x, s]"
end

@testitem "show: colour dims missing values and the type row" tags = [:unit] begin
    using ChuiFrames: Frame
    f = Frame(x = [1.0, missing])
    out = sprint((io, x) -> show(IOContext(io, :color => true, :displaysize => (24, 80), :limit => true), MIME"text/plain"(), x), f)
    @test occursin("\e[90mmissing", out)
    @test occursin("\e[90m<f64?>", out)
end

@testitem "show: grouped frames report the number of groups" tags = [:unit] begin
    using ChuiFrames: Frame, GroupIndex, column, AbstractColumn
    f = Frame(g = ["a", "b", "a"], h = [1.0, 1.0, 2.0], x = [1, 2, 3])
    g1 = Frame(getfield(f, :names), getfield(f, :columns), [:g])
    out = sprint((io, x) -> show(IOContext(io, :displaysize => (24, 80), :limit => true), MIME"text/plain"(), x), g1)
    @test split(out, '\n')[2] == "# Groups:  g [2]"
    g2 = Frame(getfield(f, :names), getfield(f, :columns), [:g, :h])
    out2 = sprint((io, x) -> show(IOContext(io, :displaysize => (24, 80), :limit => true), MIME"text/plain"(), x), g2)
    @test split(out2, '\n')[2] == "# Groups:  g, h [3]"
    # with a materialized group index, its group count is used
    gi = GroupIndex([1, 2, 1], [1, 3, 2], [1, 3, 4], AbstractColumn[column(["a", "b"])])
    g3 = Frame(getfield(f, :names), getfield(f, :columns), [:g], gi)
    out3 = sprint((io, x) -> show(IOContext(io, :displaysize => (24, 80), :limit => true), MIME"text/plain"(), x), g3)
    @test split(out3, '\n')[2] == "# Groups:  g [2]"
    @test sprint(show, g2) == "Frame: 3 × 3 [g, h, x], grouped by g, h"
end

@testitem "show: empty frames" tags = [:unit] begin
    using ChuiFrames: Frame, AbstractColumn, column
    render(f) = sprint((io, x) -> show(IOContext(io, :displaysize => (24, 80), :limit => true), MIME"text/plain"(), x), f)
    @test render(Frame()) == "# A Frame: 0 × 0"
    @test render(Frame(x = Int[])) == "# A Frame: 0 × 1\n# ℹ 1 variable: x <i64>"
    @test render(Frame(Symbol[], AbstractColumn[], Symbol[], nothing, 3)) == "# A Frame: 3 × 0"
end

@testitem "show: glimpse" tags = [:unit] begin
    using ChuiFrames: Frame, glimpse
    f = Frame(x = [1.23456789, missing, -1.0e6], s = ["a", "a very long string that goes on and on", missing])
    out = sprint(glimpse, f; context = :displaysize => (24, 80))
    lines = split(out, '\n')
    @test lines[1] == "Rows: 3"
    @test lines[2] == "Columns: 2"
    @test lines[3] == "\$ x <f64?> 1.23457, missing, -1.0e6"
    @test lines[4] == "\$ s <str?> \"a\", \"a very long string that goes on and on\", missing"
    narrow = sprint(glimpse, Frame(a = collect(1:100)); context = :displaysize => (24, 30))
    @test all(l -> textwidth(l) <= 30, split(narrow, '\n'))
    @test endswith(split(narrow, '\n')[3], "…")
    @test glimpse(devnull, f) === nothing
end

@testitem "show: binding conflicts and the banner (ADR-0014 stand-in)" tags = [:unit] begin
    using ChuiFrames: binding_conflicts, conflict_banner, _init_banner
    # Throwaway modules (a test item body is not top level, so they are built with `Module`).
    CfA = Module(:CfA)
    Core.eval(CfA, :(export foo, bar, baz, cst; foo(x) = 1; bar(x) = 2; baz = 3; const cst = 4))
    CfSame = Module(:CfSame)   # the same binding of `foo`, and a method extension of `bar`
    Core.eval(CfSame, :(export foo, bar; const foo = $(CfA.foo); const bar = $(CfA.bar); bar(::Nothing) = nothing))
    CfOther = Module(:CfOther) # a different `foo` and a different `baz`
    Core.eval(CfOther, :(export foo, baz, unrelated; foo(x) = :other; baz = 30; unrelated() = 0))
    @test binding_conflicts(CfA, [CfSame]) == Pair{Symbol, Vector{Module}}[]
    @test binding_conflicts(CfA, [CfA, CfSame, CfOther]) == [:baz => [CfOther], :foo => [CfOther]]
    io = IOBuffer()
    conflict_banner(IOContext(io, :displaysize => (24, 60)), CfA, [CfSame, CfOther])
    out = String(take!(io))
    lines = split(chomp(out), '\n')
    @test startswith(lines[1], "── Conflicts ──") && endswith(lines[1], "── ChuiFrames.conflict_banner() ──")
    @test textwidth(lines[1]) == 60
    @test lines[2] == "✖ CfA.baz   conflicts with CfOther.baz"
    @test lines[3] == "✖ CfA.foo() conflicts with CfOther.foo()"
    @test startswith(lines[4], "ℹ Qualify the name")
    # nothing to report: nothing printed
    io2 = IOBuffer()
    conflict_banner(io2, CfA, [CfSame])
    @test isempty(take!(io2))
    # the package itself: by default the modules bound in Main are scanned
    @test binding_conflicts(ChuiFrames) isa Vector{Pair{Symbol, Vector{Module}}}
    # quiet switch and non-interactive sessions
    using ChuiFrames: _banner_enabled
    @test _banner_enabled(true, Dict{String, String}())
    @test !_banner_enabled(false, Dict{String, String}())
    @test !_banner_enabled(true, Dict("CHUI_QUIET_CONFLICTS" => "1"))
    @test !_banner_enabled(true, Dict("CHUI_QUIET_CONFLICTS" => "TRUE"))
    @test _banner_enabled(true, Dict("CHUI_QUIET_CONFLICTS" => "0"))
    @test _init_banner() === nothing
    # not exported (ADR-0014 rule 2)
    @test !Base.isexported(ChuiFrames, :binding_conflicts) && !Base.isexported(ChuiFrames, :conflict_banner)
    @test Base.isexported(ChuiFrames, :glimpse)
end
