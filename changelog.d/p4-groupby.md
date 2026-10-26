### Added
- Internal key machinery for the phase-4 group-by and joins (no behaviour change to any verb).
  Spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md §2.2, §2.4:
  - `typed_keys` (canonical typed keys: one column, concrete tuples, `DictColumn` codes or values);
  - `keyhash` (agrees with `isequal` after canonicalisation, across allowed join key pairs);
  - `KeyTable` with `getorinsert!`, `lookup`, `length` and `keyvalues` (open addressing, linear probing);
  - `keyids!` and `keyhashes` (the raw first-seen key pattern);
  - `radix_partition` (a stable counting scatter on the top hash bits, optionally over several tasks);
  - `_lossless_key_promotion` and `_keypair_allowed` (the join key-pair rule).
