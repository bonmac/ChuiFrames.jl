- Changelog fragments with `###` section headings (14 files) are rewritten as list items only,
  each heading becoming a bold lead-in bullet (`- **Added:**`) with its items nested under it,
  so `julia scripts/changelog.jl fold` accepts them. No entry's text changed.
