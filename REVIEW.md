# SeatLease v1: revision review

This note records the findings an independent reviewer raised against the accepted tree, what was
reproduced, and how each was resolved. Every reproduction and fix was re-run with
`forge build --deny warnings`, `forge test`, `forge fmt --check` and `forge coverage --ir-minimum`
(`src/SeatLease.sol` at 100% lines, statements, branches and functions).

## Fixed

### High: `claim()` booked a balance gain once per entry of `tokens[]`

Reproduced with the reviewer's proof. Listing the reward token N times booked N times the amount that
arrived, so `totalCredited` outran the registry's balance and a later `sweep` paid the attacker with
rewards booked to other seats.

Fix: a token that already appears at a lower index of `tokens[]` is skipped in the post-call loop
(`_listedBefore`), so each distinct token is measured and booked exactly once. The call still succeeds
with a duplicate list, as the proof requires. Regression tests:
`test_claim_duplicateTokenEntriesBookOnce`, `test_claim_duplicateEthAndTokenEntriesBookOnce`, and the
invariant handler now lists the reward token twice on every `claim` so `invariant_solvent` covers it.

### High: `claim()` could target a reward token while nothing was booked in it

Reproduced with the reviewer's proof. The target guard only refused tokens with a non-zero
`totalCredited`, so before the first credit (or after every full sweep) a seat owner could make the
registry call `approve(spender, max)` on a reward token. The allowance survived and drained rewards
booked to other seats once they arrived.

Fix: the guard is now structural. The registry is `msg.sender` of the call, so it refuses any target it
could ever hold a balance in: a target with no code, a target that answers `balanceOf(address(this))`
with a word (`_answersBalanceOf`, a static call), plus the existing seat NFT, bond token, self and
booked-token checks. Every ERC-20 the registry could book answers `balanceOf`, so no allowance can be
created on any of them. Distributors do not implement `balanceOf` and remain valid targets. Regression
tests: `test_claim_forbidsTokenTargetEvenWhenNothingBooked`, `test_claim_forbidsTargetWithoutCode`.
The existing `test_claim_revertsWhenListedBalanceDecreases` now routes the burn through a non-token
helper because a token is no longer a valid target.

Limitation: a distributor that also exposes `balanceOf(address)` returning a word is refused. That is
the intended trade-off; such a contract could also be a token.

### Low: `credit()` with the seat NFT as `token` pulled a seat in permanently

Reproduced. `IERC721.transferFrom` shares the ERC-20 selector, and the plain `transferFrom` path does
not call `onERC721Received`, so the NFT arrived and could never be swept out. Fix: `credit()` and the
`tokens[]` list of `claim()` refuse `address(seatNFT)` with `ForbiddenToken`. Regression tests:
`test_credit_rejectsSeatNftAsToken`, `test_claim_rejectsSeatNftInTokenList`.

### Info: `isValidSignature` accepted trailing bytes after the ABI-encoded blob

Reproduced. `abi.decode` ignores trailing data. Fix: `decodeAuthorization` re-encodes the decoded
fields and reverts with `MalformedAuthorization` unless the result equals the input byte for byte, so
every accepted authorization has exactly one encoding. `isValidSignature` still returns `0xffffffff`
rather than reverting. Regression test: `test_isValidSignature_rejectsTrailingAndNonCanonicalBytes`.

## Accepted, documented

### Low: an oracle attestation is not bound to a tokenId

Reproduced as described. The `OracleAttestation` struct is defined by the network and carries no
tokenId, and the task fixes its validity conditions, so the contract cannot add the seat to the signed
data. Two seats sharing `questionHash` and `oracleSigner` are therefore cut by the same attestation,
first come first served. Operational rule, now in the `deposit` NatSpec: give each seat its own
question (for example, include the tokenId in the question text), so an attestation can only cut the
seat it was issued for.

### Low: unswept balances survive `withdraw()` and go to the next depositor of the tokenId

Behaviour is unchanged and documented on `withdraw`. Booked balances are keyed by token address and
cannot be enumerated on-chain, so the contract can neither sweep them all nor refuse withdrawal while
any exist. `sweep` is permissionless, so an owner (or anyone acting for them) can clear every known
token before withdrawing. An owner who withdraws without sweeping leaves those balances to whoever
deposits the same tokenId next.
