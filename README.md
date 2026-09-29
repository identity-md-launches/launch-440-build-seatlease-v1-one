# SEATLEASE v1

A registry that lets the owner of an IdentityMD seat (an ERC-721) let an operator run the seat while both
share the rewards the network pays to the seat's wallet. No token is created, no pool is opened, no admin
exists: every seat is administered only by the address that deposited it.

- `src/SeatLease.sol`: the registry. Holds bonds and booked rewards, records terms, answers ERC-1271.
- `src/SeatHolder.sol`: the wallet of one seat. Created by the registry on the first deposit of a token id
  (CREATE2, salt = tokenId) and reused forever after. It owns the NFT, is the address distributors pay,
  and answers ERC-1271 by deferring to the registry. Only the registry can move anything out of it.
- `src/mocks/`: a mintable seat NFT, a mintable ERC-20 (bond and reward), and a distributor that pays
  `msg.sender`. Local deployments and tests only.
- `src/LaunchToken.sol`: the fixed-supply launch token the project floor requires. The registry never
  references it.
- `script/Deploy.s.sol`: environment-driven deployment, usable unchanged on mainnet.
- `deployments/anvil-revision3-31337.json`: this revision's local deployment; `anvil-31337.json` preserves the prior example deployment.
- `REVIEW.md`: adversarial review, fixes, accepted lows.

Solidity `^0.8.26`, compiler pinned to 0.8.26 in `foundry.toml`, OpenZeppelin Contracts 5.5.0 vendored under
`lib/`. No upgradeability, no pause, no `selfdestruct`, no `delegatecall`.

## How it works

```
owner ──deposit──▶ SeatLease ──creates──▶ SeatHolder(tokenId)  ◀── owns the NFT, receives rewards
                       │                        │
operator ──take──▶     │  bonds, shares          │  execute / release / releaseNft (registry only)
network ──isValidSignature──────────────────────▶│ ──▶ SeatLease.isValidSignatureFor(holder, ...)
distributor ──pays──▶ holder ──claim / skim──▶ SeatLease books to the seat, split at booking time
anyone ──sweep / sweepFor──▶ owner and operator are paid their shares
```

1. The owner deposits a seat with its terms. The NFT moves into the seat's holder. Before offering it,
   the owner declares its ERC-20 rewards with `setRewardTokens` (up to 16; ETH is automatic).
2. An operator takes the seat: the allowed operator (Permissioned) or anyone posting the bond (Open).
3. The network pairs the operator's device: the operator signs a `WorkerAuthorization` naming the holder
   as `wallet`; the network calls the holder's `isValidSignature`, which the registry answers for the
   seat's current operator.
4. Rewards arrive at the holder (distributors paying the seat's wallet) or are pushed to the registry with
   `credit`. Holder ETH and declared tokens settle before every operator change under the outgoing split.
   Holder collections during the first hour of a tenure go entirely to the owner; afterwards they split by
   `ownerBps`. `credit` splits immediately, including during that hour. Vacant seats book everything to the owner.
5. `sweep` pays the owner and the current operator their shares; `sweepFor` pays anyone their share, including
   a cut or quit operator and a former owner. A share whose push fails stays booked.
6. The operator quits, or the owner cuts, or anyone cuts on the strength of a signed oracle attestation
   (bond forfeited to the owner). A vacant seat can be withdrawn by its owner.

## Contract reference: `SeatLease`

### Constructor

`constructor(address seatNFT, address bondToken, string workerDomainName, string workerDomainVersion)`

- `seatNFT`: the IdentityMD seat collection. Also the `verifyingContract` of the WorkerAuthorization domain.
- `bondToken`: the ERC-20 operators post on Open seats.
- `workerDomainName`, `workerDomainVersion`: the network's WorkerAuthorization EIP-712 domain, currently
  `"IdentityMD Worker"` and `"2"`. `chainId` is `block.chainid`.

The oracle domain is fixed: name `"IdentityMD Oracle"`, version `"1"`, `chainId = block.chainid`,
`verifyingContract = address(this)`.

### Constants

| Name | Value | Meaning |
|---|---|---|
| `BPS` | 10000 | Denominator of `ownerBps` |
| `MAX_LISTING_BYTES` | 280 | Maximum listing length |
| `MAX_REWARD_TOKENS` | 16 | Maximum declared ERC-20 reward tokens per seat; ETH is additional |
| `ANSWER_TYPE_BOOL` | 1 | Oracle `answerType` for booleans |
| `TERMS_DELAY` | 1 hour | Delay before changed terms or reward lists can be taken; also the holder reward warm-up |
| `SWEEP_ETH_GAS` | 100000 | Gas forwarded when `sweep` pushes ETH |
| `MAGIC_VALUE` / `FAIL_VALUE` | `0x1626ba7e` / `0xffffffff` | ERC-1271 results |
| `WORKER_AUTHORIZATION_TYPEHASH`, `ORACLE_ATTESTATION_TYPEHASH` | | EIP-712 type hashes |

### Seat state (`seat(tokenId)`)

| Field | Meaning |
|---|---|
| `owner` | Depositor. Zero means not deposited. |
| `operator` | Current operator. Zero means vacant. |
| `ownerBps` | Owner's share (0 to 10000). Holder collections during the tenure warm-up go entirely to the owner. |
| `mode` | `Permissioned` (0): only `allowedOperator` may take. `Open` (1): anyone may take by posting the bond. |
| `allowedOperator` | The only address that may take a Permissioned seat. |
| `bondAmount` | Bond pulled by `take` on an Open seat (ignored when Permissioned). |
| `bondHeld` | Bond actually received from the current operator (fee-on-transfer aware). |
| `oracleSigner` | Signer whose attestations can cut the operator. Zero disables `cutByOracle`. |
| `questionHash` | The question an attestation must answer `true` to cut the operator. |
| `listing` | Free text, at most 280 bytes. |
| `termsActiveAt` | `take` is refused before this timestamp. |
| `takenAt`, `takenBlock` | When the current operator took the seat. Zero while vacant. |

### Functions

| Function | Who | Effect |
|---|---|---|
| `deposit(tokenId, ownerBps, mode, allowedOperator, bondAmount, oracleSigner, questionHash, listing)` | NFT owner | Creates the seat's holder if it does not exist, records the caller as owner and the terms, pulls the NFT into the holder with `safeTransferFrom`. Terms are live at once unless the token id was withdrawn less than `TERMS_DELAY` ago. |
| `setTerms(same parameters)` | owner, vacant seat | Replaces the terms. They become takeable at `now + TERMS_DELAY`. |
| `setRewardTokens(tokenId, tokens[])` | owner, vacant seat | Replaces the bounded ERC-20 reward list. Rejects duplicates, the seat NFT, addresses without code and contracts not answering `balanceOf`. ETH is implicit and cannot be listed. Sets `termsActiveAt = now + TERMS_DELAY`. |
| `take(tokenId)` | anyone | Vacant seat with active terms. Permissioned: caller must be `allowedOperator`. Open: pulls `bondAmount` of the bond token from the caller. Settles holder ETH and declared tokens while vacant, then records `takenAt` and `takenBlock`. |
| `quit(tokenId)` | operator | Settles holder ETH and declared tokens, clears the operator and returns the bond. Shares already booked to the operator stay theirs. |
| `cut(tokenId)` | owner, any time | Settles holder ETH and declared tokens under the outgoing split, clears the operator and returns the bond to them. |
| `cutByOracle(tokenId, attestation, signature)` | anyone | Settles holder ETH and declared tokens under the outgoing split, clears the operator and forfeits the bond to the owner when the attestation is valid (see Oracle cut model). |
| `withdraw(tokenId)` | owner, vacant seat | Settles holder ETH and declared tokens to the owner, clears the seat and reward list and returns the NFT with `transferFrom`. The token id cannot be taken again until `TERMS_DELAY` has passed. Shares stay collectable with `sweepFor`. |
| `credit(tokenId, token, amount)` | anyone, payable | Pulls `amount` of `token` (`address(0)` = ETH as `msg.value`) from the caller into the registry and books it. Zero amounts, value mismatches, tokens that move nothing and the seat NFT are refused. |
| `claim(tokenId, target, data, tokens[])` | owner | The seat's holder calls `target` with `data` and no value. Afterwards the holder must still own the NFT and its balance of every listed token must not have decreased; the holder's whole balance of each listed token, and all of its ETH, is moved to the registry and booked. `target` may not be the NFT, the bond token, the registry, the holder, an address without code, a token with booked balances, or any contract answering `balanceOf`. |
| `skim(tokenId, token)` | anyone | Moves the holder's whole balance of `token` (`address(0)` = ETH) to the registry and books it. Reverts when nothing arrives. |
| `sweep(tokenId, token)` | anyone | Pays the owner's share and the current operator's share of `token`. Reverts `ZeroAmount` when both are zero. A share whose push fails is retained. |
| `sweepFor(tokenId, token, account)` | anyone | Pays `account` its share, whether or not it still owns or operates the seat and whether or not the seat is deposited. ETH forwards available gas, allowing receivers that need more than the `sweep` stipend to collect. |
| `redeemBond()` | anyone | Collects a bond that could not be pushed when the seat was cleared. |
| `isValidSignature(hash, signature)` | view | ERC-1271, see below. |
| `isValidSignatureFor(wallet, hash, signature)` | view | Same, additionally requiring the authorization's `wallet` to equal `wallet`. Holders call it with their own address. |
| `decodeAuthorization(signature)` | pure | Splits a signature blob; reverts `MalformedAuthorization` unless the blob is the canonical `abi.encode` of its fields. |

Views: `seat`, `holderOf(tokenId)`, `rewardTokens(tokenId)` (declared ERC-20s, excluding implicit ETH), `credited(tokenId, token)` (the seat's total unswept balance),
`share(tokenId, token, account)`, `usedRequest(requestId)`, `depositInFlight(tokenId)`, `totalCredited(token)`,
`bondOwed(account)`, `workerDomain()`, `workerDomainSeparator()`, `oracleDomainSeparator()`,
`hashWorkerAuthorization(auth)`, `hashOracleAttestation(attestation)`, `seatNFT()`, `bondToken()`.

`receive()` reverts `DirectEthNotAccepted` except while collecting a holder's ETH, so
plain ETH sent to the registry is never unattributed. Pay a seat with `credit` or by sending to its holder.

Reentrancy guards: `deposit`, `setTerms`, `setRewardTokens`, `take`, `quit`, `cut`, `cutByOracle`, `withdraw`, `credit`, `claim`, `skim`,
`sweep`, `sweepFor`, `redeemBond`.

### Events

| Event | When |
|---|---|
| `HolderCreated(tokenId, holder)` | First deposit of a token id |
| `SeatDeposited(tokenId, owner)` | `deposit` |
| `TermsSet(tokenId, ownerBps, mode, allowedOperator, bondAmount, oracleSigner, questionHash, listing, activeAt)` | `deposit`, `setTerms` |
| `RewardTokensSet(tokenId, tokens, activeAt)` | `setRewardTokens`; `withdraw` implicitly clears the list |
| `SeatTaken(tokenId, operator, bondHeld)` | `take` |
| `SeatQuit(tokenId, operator, bondReturned)` | `quit` |
| `SeatCut(tokenId, operator, bondReturned)` | `cut` |
| `SeatCutByOracle(tokenId, operator, requestId, bondForfeited)` | `cutByOracle` |
| `SeatWithdrawn(tokenId, owner)` | `withdraw` |
| `Credited(tokenId, token, from, amount)` | `credit` |
| `Claimed(tokenId, target, data)` | `claim`, after the call succeeded |
| `Skimmed(tokenId, token, amount)` | `skim` |
| `Booked(tokenId, token, amount)` | Every booking, including automatic holder settlement |
| `ShareAccrued(tokenId, token, account, amount)` | Each non-zero part of a booking |
| `Swept(tokenId, token, owner, ownerAmount, operator, operatorAmount)` | `sweep` |
| `SharePaid(tokenId, token, account, amount)` | A share pushed successfully |
| `ShareRetained(tokenId, token, account, amount)` | A share whose push failed and stays booked |
| `BondEscrowed(account, amount)` | A bond push failed; collect with `redeemBond` |
| `BondRedeemed(account, amount)` | `redeemBond` |

### Errors

| Error | Raised by |
|---|---|
| `ZeroAddress()` | constructor with a zero NFT or bond token |
| `NotSeatOwner(tokenId, caller)` | `deposit` (caller does not own the NFT), owner-only functions |
| `NotOperator(tokenId, caller)` | `quit` |
| `NotAllowedOperator(tokenId, caller)` | `take` on a Permissioned seat |
| `SeatNotDeposited(tokenId)` | anything on an undeposited seat |
| `SeatAlreadyDeposited(tokenId)` | `deposit` twice |
| `SeatNotVacant(tokenId)` | `setTerms`, `setRewardTokens`, `take`, `withdraw` while occupied |
| `SeatVacant(tokenId)` | `cut`, `cutByOracle` while vacant |
| `TermsNotActive(tokenId, activeAt)` | `take` before the terms are active |
| `InvalidBps(ownerBps)` | `ownerBps > 10000` |
| `ListingTooLong(length)` | listing over 280 bytes |
| `TooManyRewardTokens(length)` | `setRewardTokens` with more than 16 entries |
| `DuplicateRewardToken(token)` | duplicate entry in `setRewardTokens` |
| `NftNotReceived(tokenId)` | `deposit` when the NFT did not land in the holder |
| `NftNotHeld(tokenId)` | `claim` when the holder no longer owns the NFT afterwards |
| `NoOracle(tokenId)` | `cutByOracle` on a seat without `oracleSigner` |
| `OracleChainMismatch(expected, actual)` | attestation `chainId != block.chainid` |
| `OracleQuestionMismatch(expected, actual)` | attestation for another question |
| `OracleAnswerNotBool(answerType)` | `answerType != 1` |
| `OracleAnswerNotTrue()` | `answer` is not the 32-byte encoding of `true` |
| `OracleAttestationExpired(expiresAt)` | `expiresAt <= block.timestamp` |
| `OracleAttestationPredatesTenure(issuedAt, takenAt)` | issued before the current operator took the seat |
| `OracleWindowPredatesTenure(fromBlock, takenBlock)` | observation window starts before the take block |
| `OracleRequestUsed(requestId)` | replay |
| `OracleSignerMismatch(expected, actual)` | recovered signer is not `oracleSigner` |
| `WrongValue(expected, actual)` | `credit` with wrong `msg.value` |
| `ZeroAmount()` | `credit`, `skim`, `sweep`, `sweepFor` with nothing to move |
| `ForbiddenTarget(target)` | `claim` target guard |
| `ForbiddenToken(token)` | the seat NFT as a `credit`, `skim` or `claim` token, or an invalid entry in `setRewardTokens` |
| `ClaimFailed(reason)` | the distributor call reverted; `reason` is its return data |
| `HolderBalanceDecreased(token, before, afterwards)` | `claim` made a listed balance shrink |
| `NothingOwed(account)` | `redeemBond` with nothing escrowed |
| `DirectEthNotAccepted()` | plain ETH sent to the registry |
| `MalformedAuthorization()` | `decodeAuthorization` on a non-canonical blob |

## Contract reference: `SeatHolder`

Deployed by `SeatLease.deposit` with `new SeatHolder{salt: bytes32(tokenId)}(seatNFT, tokenId)`. The address is
therefore `CREATE2(registry, bytes32(tokenId), keccak256(creationCode ++ abi.encode(seatNFT, tokenId)))` and
is exposed by `SeatLease.holderOf(tokenId)` once created.

| Function | Who | Effect |
|---|---|---|
| `execute(target, data)` | registry | `target.call(data)`; returns `(ok, returndata)` without reverting |
| `release(token, amount)` | registry | Sends `amount` of `token` (`address(0)` = ETH) to the registry |
| `releaseNft(to)` | registry | `seatNFT.transferFrom(this, to, tokenId)` |
| `onERC721Received(...)` | the seat NFT | Accepts only `seatNFT`, only `tokenId`, only while `registry.depositInFlight(tokenId)` |
| `isValidSignature(hash, signature)` | view | `registry.isValidSignatureFor(address(this), hash, signature)` |
| `receive()` | anyone | Accepts ETH; it belongs to the seat and is booked by `claim` or `skim` |

Immutables: `registry`, `seatNFT`, `tokenId`. Errors: `NotRegistry(caller)`, `UnexpectedToken(collection, tokenId)`,
`EthTransferFailed(to, amount)`.

## ERC-1271: pairing a device to a leased seat

The network pairs a device by verifying an EIP-712 `WorkerAuthorization` signed by the seat's wallet. The
wallet of a leased seat is its holder (the NFT owner), a contract, so the network calls
`holder.isValidSignature(digest, signature)`. The holder defers to the registry, which validates the
authorization for the seat's current operator.

### Domain and struct

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
  name = "IdentityMD Worker"   version = "2"   chainId = block.chainid   verifyingContract = seat NFT

WorkerAuthorization(bytes32 deviceKey,address wallet,uint256 tokenId,bytes32 nonce,uint64 expiresAt,string relayOrigin)
```

`digest = keccak256("\x19\x01" ‖ domainSeparator ‖ keccak256(abi.encode(typeHash, deviceKey, wallet, tokenId, nonce, expiresAt, keccak256(bytes(relayOrigin)))))`

### Signature encoding

The `signature` argument of `isValidSignature` is exactly:

```
abi.encode(
    bytes32 deviceKey,
    address wallet,            // the seat's holder, SeatLease.holderOf(tokenId)
    uint256 tokenId,
    bytes32 nonce,
    uint64  expiresAt,
    string  relayOrigin,
    bytes   operatorSignature  // 65-byte r ‖ s ‖ v ECDSA signature by the operator over `hash`
)
```

Only the canonical `abi.encode` is accepted; trailing bytes or shifted offsets fail.

`isValidSignature(hash, signature)` returns `0x1626ba7e` only when all of the following hold, and
`0xffffffff` otherwise (it never reverts on bad input):

1. the blob decodes canonically;
2. `wallet == holderOf(tokenId)` (and, through a holder, `wallet == that holder`);
3. `hashWorkerAuthorization(decoded fields) == hash`;
4. `expiresAt > block.timestamp`;
5. the seat has an operator;
6. `ECDSA.recover(hash, operatorSignature) == operator` (low-s, 65 bytes; malleable forms fail).

### How an operator pairs

1. Read `SeatLease.holderOf(tokenId)`. That address is the `wallet` the network must see as the NFT owner.
2. Build the `WorkerAuthorization` with `wallet = holder`, the seat's `tokenId`, a fresh `nonce`, an
   `expiresAt` in the future and the relay origin. Compute the digest under the network domain
   (`SeatLease.hashWorkerAuthorization` returns it too).
3. Sign the digest with the operator key (an EOA: recovery is ECDSA, so contract operators cannot pair).
4. Submit the authorization to the network with `wallet = holder` and the ERC-1271 blob above as the
   signature. The network calls `holder.isValidSignature(digest, blob)` and receives `0x1626ba7e` while that
   operator holds the seat. As soon as the operator quits or is cut, the same blob returns `0xffffffff`.

### Worked example (verified on the recorded Anvil deployment)

| Item | Value |
|---|---|
| chainId | 31337 |
| seat NFT (verifyingContract) | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| SeatLease | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| tokenId | 1 |
| holder = wallet | `0xE4D7Ed540075309fB4151D724ac3c6CBF2da6FB9` |
| operator | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` (Anvil account 1) |
| deviceKey | `0xf43b8e2450b22a77686aca8f9501152644999adb25beb6d18407d4a184ce7c9b` (`keccak256("example device key")`) |
| nonce | `0xa5b579dc658f8a7c1ab474831d23efdc4e8b0e804abf97287bdef0f5dc36daf1` (`keccak256("example nonce")`) |
| expiresAt | 1900000000 |
| relayOrigin | `https://relay.identitymd.example` |
| domainSeparator | `0x1a7fb8c4f9436f1c632bb05f8fbaf587bafc4f752a62a0000b6715ba836877bd` |
| structHash | `0x2ca9ffd885d58041e0aad4a9c28a5774aaec44d61e96c7eedb0549444111675c` |
| digest (`hash`) | `0xeff3caa7afa52b495381fd0150fa082ddd3cd41475bb2b11758060f09ef705ec` |
| operatorSignature | `0x864bcd22398137779958c7988a7578a2e492aac0fa656b33ae84848fdc08c0cd00929759d6c77bfbe33d07a8522d92388abed9590250d1b3655b1a1cd617cc8a1c` |

`signature` blob (`abi.encode` of the seven fields):

```
0xf43b8e2450b22a77686aca8f9501152644999adb25beb6d18407d4a184ce7c9b   deviceKey
  000000000000000000000000e4d7ed540075309fb4151d724ac3c6cbf2da6fb9   wallet (holder)
  0000000000000000000000000000000000000000000000000000000000000001   tokenId
  a5b579dc658f8a7c1ab474831d23efdc4e8b0e804abf97287bdef0f5dc36daf1   nonce
  00000000000000000000000000000000000000000000000000000000713fb300   expiresAt
  00000000000000000000000000000000000000000000000000000000000000e0   offset of relayOrigin
  0000000000000000000000000000000000000000000000000000000000000120   offset of operatorSignature
  0000000000000000000000000000000000000000000000000000000000000020   relayOrigin length (32)
  68747470733a2f2f72656c61792e6964656e746974796d642e6578616d706c65   "https://relay.identitymd.example"
  0000000000000000000000000000000000000000000000000000000000000041   operatorSignature length (65)
  864bcd22398137779958c7988a7578a2e492aac0fa656b33ae84848fdc08c0cd
  00929759d6c77bfbe33d07a8522d92388abed9590250d1b3655b1a1cd617cc8a
  1c00000000000000000000000000000000000000000000000000000000000000
```

Against the recorded deployment, with seat 1 deposited and taken by the operator:

```
cast call 0xE4D7Ed540075309fB4151D724ac3c6CBF2da6FB9 "isValidSignature(bytes32,bytes)(bytes4)" <digest> <blob>  # 0x1626ba7e
cast call 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 "isValidSignature(bytes32,bytes)(bytes4)" <digest> <blob>  # 0x1626ba7e
cast call 0xE4D7Ed540075309fB4151D724ac3c6CBF2da6FB9 "isValidSignature(bytes32,bytes)(bytes4)" 0x00..01 <blob>   # 0xffffffff
```

## Oracle cut model

The owner names an `oracleSigner` and a `questionHash` in the terms. Anyone may call
`cutByOracle(tokenId, attestation, signature)` with a network `OracleAttestation` signed by that signer under
this registry's domain (`"IdentityMD Oracle"`, `"1"`, `block.chainid`, `verifyingContract = SeatLease`):

```
OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,
                  uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,
                  uint64 issuedAt,uint64 expiresAt)
```

`answer` is hashed with `keccak256(answer)` in the struct hash. The cut succeeds only if:

- the seat is deposited, occupied, and has an `oracleSigner`;
- `chainId == block.chainid`, `questionHash` equals the seat's, `answerType == 1`, `answer` is the 32-byte
  encoding of `true`;
- `expiresAt > block.timestamp`;
- `issuedAt >= takenAt` and `fromBlock >= takenBlock` of the current operator, so an attestation about a
  previous operator can never cut this one;
- `requestId` has not been used before (it is consumed);
- `ECDSA.recover(hashOracleAttestation(attestation), signature) == oracleSigner`.

Effect: the operator is cleared and the bond is paid to the owner (escrowed in `bondOwed` if the push fails).
Shares already booked to the operator remain the operator's; the bond is the penalty.

Operational rules:

- The attestation carries no tokenId. Give every seat its own question (for example include the tokenId in
  the question text) so one attestation cannot cut another seat sharing the signer.
- The oracle must fill `issuedAt` and `fromBlock` honestly. An oracle that leaves `fromBlock` at 0 can
  never cut an operator; that only hurts the owner who chose it.
- A cut cannot be enforced against an operator that quits first (see Trust model).

## Rewards and shares

- Booking paths: `credit` (any payer pushes into the registry), `claim` (the owner has the holder call a
  distributor and everything that arrived is collected), `skim` (anyone collects what the holder already holds:
  a distributor claimed by a third party, an unlisted token, ETH sent to the holder).
- Every booking creates final shares: `ownerPart = amount * ownerBps / 10000`, with the remainder to the
  operator, or everything to the owner while vacant. Rounding dust goes to the operator.
- `take`, `quit`, `cut` and `cutByOracle` first collect the holder's ETH and all owner-declared reward tokens
  under the outgoing split. `withdraw` collects them before clearing the owner. This protects funds already
  in the holder against both a new taker and an owner cutting before a skim. The reward list cannot change
  during a tenure; replacing it while vacant delays `take` by one hour, as other terms changes do.
- Collections by `skim`, `claim` and automatic settlement while `block.timestamp < takenAt + TERMS_DELAY`
  belong entirely to the owner. At equality, normal sharing starts. Every new take restarts this warm-up.
  It blocks atomic take/claim-for-holder/skim/sweep/quit extraction, including for undeclared tokens and
  rewards that were claimable before the take. `credit` remains immediately shared because it transfers
  new funds directly to the registry and books them in the same call.
- This is settlement at tenure boundaries plus a warm-up, not historical accrual tracking. ERC-20 transfers
  and arbitrary distributors provide no arrival/earning timestamp the registry can query. Unlisted tokens
  are not settled at boundaries; unclaimed distributor entitlements are not holder balances. After warm-up,
  their later collection uses the current split. Declare all expected tokens and prefer `credit` or timely
  distributor payments to the holder when allocation to an exact tenure matters.
- `credited(tokenId, token)` is the seat's unswept total; `share(tokenId, token, account)` is what one account
  is owed. `totalCredited(token)` is what the registry owes across all seats.
- `sweep` pays the owner and the current operator using `SWEEP_ETH_GAS` for each ETH push, so a receiver
  cannot consume the other recipient's gas. `sweepFor` pays just one account (including former operators
  and owners) and forwards available gas for ETH. Supply enough transaction gas for a heavy receiver;
  a failed push retains the share (`ShareRetained`), and an out-of-gas transaction rolls back. Both paths
  are reentrancy guarded and copy no ETH return data. ERC-20s use a tolerant transfer.
- Invariants held by the test suite: the NFT sits in its holder exactly while the seat is deposited and the
  registry never holds one; swept never exceeds credited; the registry's balance covers booked rewards plus
  bonds; shares sum to `credited` per seat and token.

## Trust model and operational responsibilities

- **Owner-chosen terms.** The owner picks `oracleSigner`, `questionHash`, `ownerBps`, mode and bond. An
  operator must read the terms, `rewardTokens` and `termsActiveAt` before taking, and take within `TERMS_DELAY` of reading
  active terms: a `take` that lands within that window is seated under exactly those terms or reverts
  `TermsNotActive`. The owner cannot change terms while the seat is occupied.
- **Owner can cut any time.** `cut` settles declared holder balances under the outgoing split, returns the
  bond and ends the tenure. Booked operator shares remain payable to that operator. Holder collections
  during warm-up belong to the owner regardless of who ends the tenure.
- **Declare rewards before leasing.** ETH and declared, transferable ERC-20 holder balances are settled at
  operator changes; unlisted tokens and unpaid distributor entitlements have the limits described above.
  Declared tokens must keep `balanceOf` and transfers usable. A paused, blocklisting, malicious or excessively
  expensive token can block settlement and therefore operator changes and withdrawal; such tokens are not
  supported reward-list entries. While vacant, the owner can replace the list. Verify token behavior before
  taking. The list is bounded and only the owner can change it, so third-party dust cannot grow exit costs.
- **Distributor behavior.** `claim` calldata is chosen by the owner. A
  distributor with a recipient parameter (`claimTo(address)`) lets the owner send the payout elsewhere,
  and the owner may never call `claim` at all. Anyone, including the operator, may `skim` what a distributor
  pays the holder directly and may call permissionless distributors with the holder as the account. Operators
  should prefer seats whose distributors pay the holder unconditionally and whose reward list is complete.
- **Quit is instant.** The Open-mode bond deters misbehaviour the oracle attests while the operator is still
  seated. An operator watching the mempool can quit before a `cutByOracle` lands and keeps its bond; the
  attestation can then never be used against a later tenure (tenure binding), even if the same operator
  quits and retakes in the same block after the attestation's observation window began. Owners needing stronger
  guarantees should use Permissioned mode with a counterparty they trust. Changing this needs an unbonding
  window, which the brief's `quit` specification does not allow.
- **EOA operators only.** Pairing recovers an ECDSA signature from the operator, so a contract cannot operate.
- **Push recipients.** A recipient that rejects ETH or is blocklisted by a reward token keeps its share booked
  until it can receive; nobody else is blocked.
- **The registry is nobody's wallet.** ETH forced into the registry with `SELFDESTRUCT`, or tokens transferred
  straight to the registry address, cannot be attributed to a seat and are unrecoverable. Pay seats with
  `credit` or by paying their holder.
- **Only `deposit` may move a seat into its holder.** Never use plain ERC-721 `transferFrom` to send the NFT
  to a holder address, including after withdrawal or through a marketplace. It bypasses the receiver hook,
  creates no deposit record and permanently locks the NFT (effectively burns it). `deposit`, `withdraw` and
  direct `releaseNft` cannot recover it; there is no admin rescue and no reliable on-chain previous-owner
  attribution. Sending rewards to a holder is separate from transferring the seat NFT.
- **Holder reuse.** A token id keeps its holder across withdraw and redeposit. Rewards paid to the holder while
  the seat is not deposited are booked to whoever deposits the token id next (they belong to the NFT, which
  that depositor holds).
- **Distributors that answer `balanceOf`.** `claim` refuses any target that answers `balanceOf(address)`,
  because the holder must never be able to `approve` a token it holds. Such distributors can still be claimed by
  anyone directly, with the holder as the account, and then skimmed.

## Deployment

### Local (recorded)

`deployments/anvil-revision3-31337.json` records this revision deployed on a fresh local Anvil chain
(chain id 31337, port 8546). The unchanged script deployed MockSeatNFT, MockERC20 and SeatLease in block 1.
The registry is `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`, transaction
`0x517c4f181553317b5f223c15462d01cc512a90d5560c5cebd57dbaadccff0280`; deployed runtime is 23,747 bytes.
The JSON includes all addresses, transaction hashes, blocks, gas usage and constructor parameters.
No public chain or mainnet deployment was performed.

The prior revision's `deployments/anvil-31337.json` is retained below for the worked pairing example.
It records the deployment produced by:

```
anvil --port 8545 --chain-id 31337
DEPLOY_MOCKS=true PRIVATE_KEY=<anvil key 0> forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

| Contract | Address | Tx | Block |
|---|---|---|---|
| MockSeatNFT | `0x5FbDB2315678afecb367f032d93F642f64180aa3` | `0xd475fc0188083cb9ff9d3d0112a8003279d10d3c7e813df8ae8ab06ee80476b5` | 1 |
| MockERC20 (bond) | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` | `0x6734c5e65e6f5819815e4fe76b7a1ed00d06c94cd9826f41c07ef4ca397c22e9` | 1 |
| SeatLease | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` | `0x43c2c6d640b835c6c802137d3d368ffb011f2b047b0cea58e87b6c62779f526c` | 1 |

Seat 1 was then minted to the deployer, deposited (Permissioned, 5000 bps, operator = Anvil account 1) and
taken by the operator in blocks 6 to 9; its holder is `0xE4D7Ed540075309fB4151D724ac3c6CBF2da6FB9`. Tx hashes
are in the JSON. No other chain was deployed to; this request did not enable a public deployment.

### Mainnet steps

The script reads its configuration from the environment and refuses to deploy mocks on chain id 1.

1. Set `SEAT_NFT` to the IdentityMD seat NFT and `BOND_TOKEN` to the ERC-20 to bond with. Leave
   `DEPLOY_MOCKS` unset. Set `WORKER_DOMAIN_NAME` / `WORKER_DOMAIN_VERSION` only if the network's
   WorkerAuthorization domain differs from `"IdentityMD Worker"` / `"2"`.
2. Provide the deployer key with `PRIVATE_KEY`, or leave it unset and pass `--account` / `--ledger` to forge.
3. Simulate: `forge script script/Deploy.s.sol --rpc-url $RPC_URL`.
4. Broadcast: `forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify` (add
   `--etherscan-api-key`). Keep the generated `broadcast/` record.
5. Check on chain: `seatNFT()`, `bondToken()`, `workerDomain()` and `workerDomainSeparator()` must match the
   network's parameters; `oracleDomainSeparator()` must match what the oracle signs under.
6. Publish the SeatLease address. Holders are created lazily by `deposit`; their addresses are deterministic
   (`holderOf`).

Nothing in the contract can be changed after deployment: there is no owner, no upgrade path and no pause. A
wrong constructor parameter means a new deployment.

## Development

```
forge build --deny warnings   # lint runs after the build
forge test                    # unit, fuzz and invariant tests; no environment variables are read
forge fmt --check
forge coverage --ir-minimum
forge snapshot                # .gas-snapshot
```

Tests never read the environment and pass in any order and in parallel. The deploy script's `run()` is the
only place environment variables are read; tests call `deploy(Config)` directly.
