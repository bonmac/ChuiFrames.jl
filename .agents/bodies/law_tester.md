## Operating rules

- Use the law kits the core package exports; pass Supposition generators in, never make Supposition a runtime dependency.
- One `@testitem` per instance and law family, tagged `:laws`.
- Prove each law test can fail: plant a violation locally, show the failure, remove it. Report that you did.
- Generators must include the edge cases: empty, singleton, `missing`, large, and nested values.
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
