# Frozen Helpers live coordinator runtimes

`deployed-helpers-live-coordinator.hex` contains the installed owner coordinator
at `0x9a8Cb1aE2624ca2f4245677426a894c78eBB585D`, read from Ethereum mainnet block
`26142051`. Its 14,459-byte runtime hashes to
`0x444259d415cc05ad1cf101cd6601ea387aad01629e0b109f7de6431e2c6a998c`.
Helpers `0x30e9aFD21A30B2629BE33508A131AC890368f534` reports coordinator
generation one at that block. Optional-initializer migration tests load these
exact bytes to exercise the mandatory-initializer baseline.

`legacy-helpers-live-coordinator.hex` preserves the older reviewed target of
the legacy registry-retirement migration. Its 14,459-byte runtime hashes to
`0x3879803540004ef762c8e7398c0824f87b8c6340862dce07e1ccf72af36e9bec`.
It was recovered from the prior optimized mandatory-initializer source using
the historical metadata digest and Solidity 0.8.36 patch byte already asserted
by those tests. Their existing full-runtime hash assertion remains unchanged.

Both fixtures are contract bytecode. They contain no signatures or credentials.
New source compilations use the published optional-initializer shared policy;
they must not reconstruct historical mandatory-initializer bodies from that
successor source.
