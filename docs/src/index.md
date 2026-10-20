# ChuiFrames.jl

Data frames for the Chui ecosystem. **Status: pre-release, phase 2 (eager frame).** The API is
not stable before ChuiFrames 0.1.0.

```@docs
ChuiFrames
```

## Differences from dplyr

ChuiFrames follows dplyr's semantics, except where Julia's do differently. The differential test
suite (`test/engine/differential_dplyr_tests.jl`) encodes each of these as an expected
difference.

- **NaN follows IEEE** (ADR-0002 rule 12). `NaN .> 1` is `false` and `NaN .!= 1` is `true`, so
  `filter(c.x .!= 1)` and `filter(.!(c.x .> 1))` keep NaN rows, where dplyr drops them.
- **`skipmissing` keeps NaN.** `sum(skipmissing(c.x))` skips `missing` only, so a NaN makes the
  sum NaN. R's `sum(x, na.rm = TRUE)` drops NaN as well. To match R, drop NaN rows first:
  `filter(.!isnan.(coalesce.(c.x, 0.0)))`.
- **`summarise(…; by = :g)` sorts by key** (CF-008), as `group_by` does. dplyr's `.by` keeps
  the order in which groups first appear. Add `arrange` afterwards for another order.
- **Group-key order is not `arrange` order** (as in dplyr): group keys sort NaN before
  `missing`; `arrange` ties NaN and `missing` and puts them last in both directions.
