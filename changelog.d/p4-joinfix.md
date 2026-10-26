### Fixed
- The DataAPI join methods (`innerjoin`, `leftjoin`, `rightjoin`, `outerjoin`, `semijoin`,
  `antijoin`) throw an `ArgumentError` when given a `by` keyword: DataAPI's methods take `on`,
  and a `by` passed alongside `on` used to win silently. `crossjoin` throws an `ArgumentError`
  for `on` or `by` (a cross join has no keys). Every other keyword is still forwarded unchanged.
