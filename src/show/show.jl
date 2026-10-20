# Printing entry point (sub-lane `p2-show`): tibble-style printing of frames, `glimpse`, and
# the name-conflict banner stand-in (ADR-0014). Included last by src/ChuiFrames.jl, which calls
# `_init_banner()` from `__init__`.
#
# Layout decisions, each following R's tibble 3.3.0 / pillar output (quoted in the files):
# - header `# A Frame: 3 × 2` (tibble's dim_desc, thousands marked with `,`), then
#   `# Groups:  g, h [3]` for grouped frames;
# - type labels under the headers use short Arrow/Polars dtype names in tibble's brackets:
#   `<i64>`, `<f64>`, `<str>`, `<bool>`, `<binary>`, `<date>`, `<dttm>`, `<list[i64]>`,
#   `<struct[2]>`, `<dict[str]>`, `<any>`, `<missing>`, or the Julia type name for other object
#   columns (`<Symbol>`); `?` marks a nullable column (format.jl);
# - numbers: 3 significant digits, decimal points aligned, scientific notation when a column
#   is wider than 13 characters in fixed notation (format.jl);
# - `missing` for missing values, dimmed when the io has `:color`;
# - 10 rows when there are more than 20, else all, within the display height; columns that do
#   not fit the display width are listed in a `# ℹ N more variables:` footer (frame_show.jl).

include("format.jl")
include("frame_show.jl")
include("glimpse.jl")
include("banner.jl")

export glimpse
