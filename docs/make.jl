# Build: julia scripts/ci.jl docs  (develops this package into docs/ first; ADR-0008)
using Documenter
using ChuiFrames

DocMeta.setdocmeta!(ChuiFrames, :DocTestSetup, :(using ChuiFrames); recursive = true)

makedocs(;
    sitename = "ChuiFrames.jl",
    modules = [ChuiFrames],
    format = Documenter.HTML(; prettyurls = get(ENV, "CI", "false") == "true"),
    pages = ["Home" => "index.md", "Lazy queries" => "lazy.md", "API" => "api.md", "Performance" => "performance.md"],
    # Only the API (exported names) must be in the manual; internal docstrings stay in the
    # source (phase-2 review B2).
    checkdocs = :exports,
    # No git remote yet (pushing waits for the user), so no source links; set `repo` then.
    remotes = nothing,
)

# deploydocs(...) is added once the user approves a remote and GitHub Pages (ADR-0008 §1).
