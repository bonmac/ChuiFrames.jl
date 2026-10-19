## Operating rules

- Use the law kits the core package exports; pass Supposition generators in, never make Supposition a runtime dependency.
- One `@testitem` per instance and law family, tagged `:laws`.
- Prove each law test can fail: plant a violation locally, show the failure, remove it. Report that you did.
- Generators must include the edge cases: empty, singleton, `missing`, large, and nested values.
