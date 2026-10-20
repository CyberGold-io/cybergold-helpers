# Historical exact-input fixtures

These test-only fixtures preserve the 54-selector Helpers base and two-selector Market extension that preceded universal exact input. The interface, selector tables and generated ABI/topology JSON are frozen from `2675071` (the feature branch base). The deployment fixtures retain the former setup and selectors. Retired execution bodies reside only here; none forwards execution into the universal engine.

The four legacy execution facets inherit the pruned current production facets, so retained previews and exact-output methods continue to exercise current production code. Shared custody/authorization/recovery primitives are also current production code. These fixtures qualify historical behavior and ABI boundaries; they do not assert byte-for-byte reproduction of previously deployed runtime. Active deployment conformance is tested separately.
