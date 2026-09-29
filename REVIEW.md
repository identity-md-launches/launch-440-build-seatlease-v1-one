# SeatLease v1: review record

This note records the findings independent reviewers raised against the accepted trees, what was
reproduced, and how each was resolved. Every reproduction and fix was re-run with
`forge build --deny warnings`, `forge test`, `forge fmt --check`, `forge snapshot` and
`forge coverage --ir-minimum`. The reviewers' proofs were copied under `test/scratch/` and run before and
after each fix.

The review followed the solidity-security-review and pashov checklists: who can call what, value in and
out (reentrancy, push versus pull, lying tokens, rounding, conservation), arithmetic, time and ordering
(front-running, expiries), signatures (replay, malleability, ERC-1271), external dependencies, and what
the tests do not cover.

## Revision 2 (this round)

### High: `claim()` booked the registry-wide balance gain to whichever seat the caller named

Reproduced with the reviewer's proof. Every seat was held by one address, so any distributor paying
the holder paid once for all seats and the first owner to claim booked everything.

Fix: each seat now has its own wallet, `SeatHolder` (`src/SeatHolder.sol`), created by `deposit` with
CREATE2 (salt = tokenId) and reused for every later deposit of that id. The holder owns the NFT, is the
address distributors pay, makes the `claim` call and hands what arrived to the registry, which books it
to that seat only. A payout keyed to another seat's holder, or to the registry address, never reaches the
caller's holder. The network's ERC-1271 check follows the NFT owner, so the holder answers
`isValidSignature` by deferring to `SeatLease.isValidSignatureFor(address(this), ...)`, and the
`WorkerAuthorization.wallet` must be the seat's holder (an authorization naming the registry, or another
seat's holder, fails). The registry no longer implements a receiver hook at all, so a safe transfer to it
reverts inside the NFT. Regression tests: `test_claim_booksOnlyTheCallersSeatPayout`,
`test_claim_payoutKeyedToRegistryIsNotBookedToAnySeat`, `test_claim_isMadeByTheHolderNotTheRegistry`,
`test_deposit_holderIsDeterministicAndReused`, `test_isValidSignature_holderAnswersForItsSeat`,
`test_isValidSignature_rejectsRegistryAsWallet`, `test_isValidSignature_rejectsAnotherSeatsHolderAsWallet`,
`invariant_nftHeldIffDeposited` (the registry never holds a seat). The worked example in the README was
verified against the recorded Anvil deployment through both the holder and the registry.

### High: `take()` bound the operator to whatever terms were in storage when it landed

Reproduced with the reviewer's proof (owner front-runs `take` with `setTerms` swapping the oracle
signer, then forfeits the bond to itself).

Fix, keeping the `take(tokenId)` ABI the proofs call: terms carry an activation time. `setTerms` sets
`termsActiveAt = now + TERMS_DELAY` (1 hour) and `take` reverts `TermsNotActive` before it. Terms recorded
at `deposit` are live at once, except that `withdraw` also sets `termsActiveAt = now + TERMS_DELAY` on the
token id so a withdraw-and-redeposit cannot swap terms under a pending `take`. The guarantee: a `take`
that lands within `TERMS_DELAY` of reading active terms is seated under exactly those terms or reverts.
`TermsSet` carries `activeAt`. Regression tests: `test_take_refusedUntilChangedTermsAreActive`,
`test_take_frontRunWithSwappedOracleSignerDoesNotSeatTheVictim`,
`test_take_refusedAfterWithdrawAndRedepositUntilDelayPasses`, `test_deposit_longAfterWithdrawIsActiveAtOnce`,
`test_take_permissionedIsDelayedToo`; the invariant handler gained `setTerms` and `passTime` actions.

### High: `sweep()` split the whole booked balance by the operator seated at sweep time

Reproduced with the reviewer's proof (stranger takes a vacant Open seat carrying an unswept balance,
sweeps half of it, quits with the bond back) and the owner-side mirror (`cut`, then sweep 100%).

Fix: attribution at booking time. `_book` splits every amount by the operator and `ownerBps` in force at
that moment (vacant means all to the owner) into per-(seat, token, account) shares. `sweep` pays the owner's
share and the current operator's share; `sweepFor(tokenId, token, account)` pays any account its share,
whether or not it still owns or operates the seat and whether or not the seat is deposited. Later takes,
quits and cuts therefore only affect later bookings. Design decision on the reviewer's open question: an
operator that is cut, including by the oracle, keeps shares already booked to it; the bond is the penalty.
Views: `share(tokenId, token, account)`; `credited` stays the seat's unswept total and
`invariant_sharesSumToCredited` ties the two together. The previously accepted Low (unswept balances passing
to the next depositor) is closed by the same change: a former owner's share stays with the former owner.
Regression tests: `test_sweep_takerGetsNothingBookedBeforeItsTenure`,
`test_sweep_sharesBookedDuringTenureStayWithCutOperator`,
`test_sweep_attributesEachBookingToTheTenureItHappenedIn`, `test_sweep_ownerOperatingOwnSeatIsPaidOnce`,
`test_sweepFor_paysFormerOwnerAfterWithdrawAndNotTheNextDepositor`, `test_sweepFor_revertsWhenNothingBookedToAccount`,
`test_book_emitsSharesAtBookingTime`, plus the existing 0 / 5000 / 10000 bps and vacant sweep tests.

### High: `cutByOracle()` accepted an attestation issued before the current operator took the seat

Reproduced with the reviewer's proof. Fix: `take` records `takenAt` and `takenBlock`; `cutByOracle`
requires `attestation.issuedAt >= takenAt` (`OracleAttestationPredatesTenure`) and
`attestation.fromBlock >= takenBlock` (`OracleWindowPredatesTenure`), so both the issue time and the
observation window lie within the current tenure. Regression tests:
`test_cutByOracle_rejectsAttestationIssuedBeforeCurrentTenure`,
`test_cutByOracle_rejectsObservationWindowStartingBeforeCurrentTenure`,
`test_cutByOracle_acceptsAttestationIssuedAtTakeTime`,
`test_cutByOracle_ownerCannotRecycleAttestationAgainstNextOperator`.

### Medium, disputed: `quit()` returns the bond instantly, so a watching operator escapes forfeiture

Reproduced as described. Not changed: the reviewer's own held proof for the stale-attestation finding
asserts the operator's full bond balance immediately after `quit`, so any unbonding window or delayed
release fails a proof this work is held to, and the brief specifies `quit` as returning the bond.
Documented as an accepted limitation in the README (Trust model): the Open-mode bond deters misbehaviour
the oracle attests while the operator is still seated; the tenure binding above guarantees an escaped
attestation can never be turned against the next operator. Changing this needs the quit specification and
that proof revised first.

### Medium: rewards reaching the registry outside a `claim` delta or `credit` were never bookable

Reproduced. With per-seat holders, everything that reaches a seat's holder belongs to that seat, so
`skim(tokenId, token)` (anyone) moves the holder's whole balance of a token (or ETH) to the registry and
books it. This covers third-party claims on account-keyed distributors, tokens not listed in `claim`
(`claim` now also collects the holder's whole balance of each listed token and all its ETH), and ETH sent or
forced into the holder, which has a plain `receive`. Regression tests: `test_skim_booksPushedRewardsFromThirdPartyClaim`,
`test_skim_booksTokenNotListedInClaim`, `test_skim_booksEthSentToHolder`,
`test_skim_booksReceivedAmountOfFeeOnTransferToken`, `test_skim_reverts`, `test_skim_isReentrancyGuardedViaClaim`;
the invariant handler gained a `skim` action. Residual accepted Low below.

### Low: `withdraw()` used `safeTransferFrom`, locking seats of contract owners without a receiver hook

Reproduced with a `PlainWallet` actor. Fix: the holder returns the seat with `transferFrom`
(`SeatHolder.releaseNft`); the depositor proved custody when it deposited. Regression test:
`test_withdraw_worksForContractOwnerWithoutReceiverHook`.

### Low: `sweep()` pushed with revert-on-failure, so one recipient could block the other's share

Reproduced. Fix: shares are pushed with a non-reverting transfer (`_tryPay`: ETH with a `SWEEP_ETH_GAS`
stipend and no return-data copy, via inline assembly; ERC-20 through the same tolerant transfer used for
bonds). A share whose push fails stays booked (`ShareRetained`) and is collectable later with `sweepFor`;
the other party is paid regardless. Regression tests: `test_sweep_retainsShareWhenOperatorRejectsEth`,
`test_sweep_retainsShareWhenOwnerRejectsEth`, `test_sweep_retainsShareWhenRecipientBurnsAllGas`,
`test_sweep_retainsShareWhenTokenRefusesRecipient`, `test_sweep_isReentrancyGuarded`.

### Low: `claim()` lets the owner pick calldata and route recipient-parameterised payouts away

Reproduced with a `ClaimToDistributor` actor. Not fixable in the contract without a per-seat allowlist the
brief does not ask for; documented as a trust assumption in the README (Trust model) and pinned by
`test_claim_ownerCanRouteRecipientParameterisedPayoutsAway_documented`. Operators are protected for rewards
that reach the seat's wallet; anyone may `skim` what a distributor pays the holder directly.

### Low: README and deployment record were missing

Added `README.md` and `deployments/anvil-31337.json` (the `broadcast/` directory is excluded from git by
the workspace, so the record lives under `deployments/`).

## Revision 1 (previous round, still in force)

### High: `claim()` booked a balance gain once per entry of `tokens[]`

A token that already appears at a lower index of `tokens[]` is skipped (`_listedBefore`), so each distinct
token is collected once. Tests: `test_claim_duplicateTokenEntriesBookOnce`,
`test_claim_duplicateEthAndTokenEntriesBookOnce`; the invariant handler lists the reward token twice.

### High: `claim()` could target a reward token while nothing was booked in it

The target guard is structural: no target without code, no target that answers `balanceOf(address(this))`
(`_answersBalanceOf`), plus the seat NFT, bond token, registry, holder and booked-token checks. With
per-seat holders the guard protects the holder's own unbooked rewards from an `approve` rather than other
seats' balances, which the holder cannot reach at all. Tests: `test_claim_forbidsTokenTargetEvenWhenNothingBooked`,
`test_claim_forbidsTargetWithoutCode`. Limitation: a distributor that also answers `balanceOf` is refused as
a `claim` target; it can be claimed by anyone directly with the holder as the account and then skimmed.

### Low: `credit()` with the seat NFT as `token` pulled a seat in permanently

`credit`, `skim` and the `tokens[]` list of `claim` refuse `address(seatNFT)` with `ForbiddenToken`.

### Info: `isValidSignature` accepted trailing bytes after the ABI-encoded blob

`decodeAuthorization` re-encodes the decoded fields and reverts `MalformedAuthorization` unless the result
equals the input byte for byte. `isValidSignature` still returns `0xffffffff` rather than reverting.

## Accepted, documented

- **An oracle attestation is not bound to a tokenId.** The struct is the network's and carries none. Give
  every seat its own question (README, Oracle cut model).
- **Quit is instant.** See the disputed Medium above.
- **The registry is nobody's wallet.** ETH forced into the registry with `SELFDESTRUCT`, or tokens transferred
  straight to the registry address, cannot be attributed to a seat and are unrecoverable. Every other route
  (`credit`, the holder, `claim`, `skim`) is attributable. The README tells payers which addresses to use.
- **Holder reuse across deposits.** Rewards paid to a holder while its seat is not deposited are booked to
  whoever deposits the token id next; they belong to the NFT, which that depositor holds.
- **EOA operators only.** Pairing recovers an ECDSA signature.
- **Runtime size.** `SeatLease` is 22,360 bytes at `optimizer_runs = 200` (2,216 under EIP-170) because the
  holder's creation code is embedded. Neither contract contains `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`;
  a scan mirroring the project floor was run during the review.

## Coverage

`src/SeatLease.sol`: 100% of functions and branches; every line except the inline-assembly `call` in
`_tryPay`, which `forge coverage` does not instrument although every ETH sweep test executes it.
`src/SeatHolder.sol`: 100% lines, statements, branches and functions. `src/LaunchToken.sol` and the mocks:
100% of lines and functions.

## Linter notes

`foundry.toml` excludes a handful of stylistic lints that flag intentional choices: events are emitted
before the interaction they describe; expiries compare against `block.timestamp` by design; `sweep`
pushes ETH to the seat's own owner and operator; `claim` reverts inside its token loop on purpose; the
mock NFT uses `_mint` so tests can mint to any address. Four inline `forge-lint: disable-next-line`
markers cover the `uint64` timestamp and block-number casts, and two cover the deliberate post-call
balance read in `_collect`.
