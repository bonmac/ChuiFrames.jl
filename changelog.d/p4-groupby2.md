### Changed
- Join key pairs (internal, for the phase-4 joins): an integer (or `Bool`) key paired with a float
  key is now allowed and compared as `Float64`, as dplyr does (the user's ★ K4 answer,
  2026-10-26). New internal `_keypair_compare_type(Sx, Sy)` gives the type both sides are
  converted to; above 2^53 two different integer keys can match the same `Float64` key.
