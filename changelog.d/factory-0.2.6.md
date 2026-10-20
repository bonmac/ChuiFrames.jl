- Synced the ecosystem factory template 0.2.5 -> 0.2.6 (see `.factory-version`): lanes that work in
  their own worktrees; a seeded `JuliaTestItems.toml` keeps lane worktrees out of test discovery
  (test compat `TestItemRunner = "1.3.2"`); testing notes for Supposition `record=false db=false`,
  the LTS manifest and a gitignored `test/SuppositionDB/`.
