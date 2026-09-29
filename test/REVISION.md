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

## Follow-up against the accepted revision 3 implementation

The initial warning-denying build passed, but the full test run exposed stale
expectations in the earlier contributor tests:

- The bond-token claim test expected a 50/50 split immediately after `take`,
  during the newly introduced holder warm-up. It now advances to the end of that
  window before checking the normal split and bond isolation.
- The claim callback test expected `NotSeatOwner` from `setTerms`; its new
  reentrancy guard correctly runs first. The test checks that exact guard error
  wrapped in `ClaimFailed` and still checks that terms remain unchanged.
- The wider stateful handler assigned holder claims to operators during warm-up.
  Its baseline counterexample shrank to `deposit`, `take`, `claim`. Its ledger now
  distinguishes direct credits, which share immediately, from holder collections.

The same handler now drives reward-list changes, direct holder funding and skims.
It tracks pending holder funds independently from booked shares and accounts for
automatic settlement before takes, quits, owner/oracle cuts and withdrawals.
Bond inflows are measured from the taker's debit, so settlement of bond-token
rewards cannot inflate the recorded bond. A new invariant compares actual holder
balances with pending inputs and checks, per asset:

`direct credits + holder funding = pending + booked + paid`

The existing entitlement, bond, custody, replay and signature invariants remain
in place. Deterministic handler sequences pin direct credit during warm-up,
collections one second before and exactly at expiry, combined pending/claimed
amounts, all three exit paths and recovery of shares after withdrawal. Another
regression blocks a declared reward transfer during `cutByOracle`: the request,
operator, bond and earlier ETH settlement all roll back, and the same signed
attestation succeeds once transfers resume.

These changes stay in `test/`; the accepted contracts and configuration are not
modified. The documented limitations on undeclared or untransferable rewards,
instant bond return and unsolicited NFT transfers are unchanged.

Validation: `forge build --deny warnings` passes. The full `forge test` run passes
269 grouped results with zero failures or skips, including 12 invariant properties
over 8,192 randomized handler calls. The wider handler retains its inline 96-run,
64-call configuration with failures on unexpected reverts. No new implementation
defect was identified in these cases.

The refreshed gas snapshot contains 70 deterministic tests, including the revision
3 regressions and the new handler sequences:

```sh
forge snapshot --match-contract 'SeatLease(Adversarial|StatefulInvariant|Revision3)Test' \
  --match-test '^test_' --snap test/seatlease-revision.gas-snapshot
```

For final validation, build outputs, caches, coverage reports and failure artifacts
were directed to `test/scratch/` using CLI options and per-process Foundry settings.
No test changes the shared environment with `vm.setEnv`.

The full `forge coverage --ir-minimum --report summary --report lcov` run also
passes all 269 results. SeatLease measures 99.68% lines (313/314), 99.75%
statements (405/406), 100% branches (80/80) and 100% functions (45/45).
SeatHolder reaches 100% in all four categories. LCOV marks only SeatLease's
assembly ETH `call` at line 860 uncovered, although successful ETH payout tests
exercise it; Foundry warns that minimum-IR source mappings can be inaccurate.
These are the measured results, not a claim of complete repository coverage.
