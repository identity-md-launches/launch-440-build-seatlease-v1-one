# SeatLease test revision

The inherited adversarial suite did not compile against the accepted per-seat-holder
implementation: it referenced removed registry errors and receiver hooks and used
the old reentrant-distributor constructor. Its stateful handler also assumed registry
NFT custody and redistribution of rewards at sweep time.

The revision preserves these suites and updates their fixtures and expectations:

- Claims pay the seat's holder; duplicate listings still cannot double-book rewards
  or hide a balance decrease. A rejected claim must roll back the mock burn.
- The terms delay and oracle tenure checks are satisfied when testing unrelated
  behavior, so failures exercise the intended guard.
- Rewards booked to an operator remain theirs after quit or oracle cut. Term changes
  cannot reassign previously booked rewards.
- The stateful handler maintains an independent entitlement ledger across three
  seats, three actors and three assets. Actual recipient balance changes determine
  swept totals. Both current and former participants can collect their shares.
- Custody tracking follows each holder, and signatures are checked through both the
  registry and holder. A deterministic handler sequence checks both modes, all three
  exit routes, delayed terms, self-operation, withdrawal and share recovery.

Validation uses the repository's Foundry configuration and the existing inline
96-run, 64-call settings for the wider handler. `forge test` passes 249 grouped test
results, including 11 invariant properties over 8,192 randomized handler calls.
`forge build --deny warnings` passes.

`forge coverage --ir-minimum --report summary` also passes all 249 results. It reports
SeatLease at 99.65% lines (287/288), 99.73% statements (370/371), 100% branches
(76/76) and 100% functions (42/42). SeatHolder reaches 100% in all four categories.
These are the measured figures, not a claim of 100% coverage for the whole repository;
Foundry warns that minimum-IR instrumentation can produce inaccurate source mappings.

The gas snapshot covers the 52 deterministic tests in the two revised suites; it
excludes fuzz and invariant gas measurements because their call sequences vary:

```sh
forge snapshot --match-contract 'SeatLease(Adversarial|StatefulInvariant)Test' \
  --match-test '^test_' --snap test/seatlease-revision.gas-snapshot
```

No new implementation defect was identified in these revised cases.
