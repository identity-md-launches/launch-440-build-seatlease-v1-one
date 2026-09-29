// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./utils/Base.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {SeatHolder} from "../src/SeatHolder.sol";
import {MockDistributor} from "../src/mocks/MockDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TunableToken, ReentrantDistributor, Burner} from "./utils/Actors.sol";

/// @dev Distributor that pays the caller in the bond token, to check that a bond-token reward is booked
///      separately from the bond that is held for the operator.
contract BondPayingDistributor {
    IERC20 public immutable token;

    constructor(IERC20 token_) {
        token = token_;
    }

    function claim(uint256 amount) external {
        token.transfer(msg.sender, amount);
    }
}

/// @dev Claim target with no declared functions whose fallback answers every call with one word, so the
///      registry's `balanceOf` probe sees a token-shaped contract. The fallback writes no state: the probe is a
///      static call, and a fallback that wrote state would revert under it and not look like a token (nor could
///      such a token ever be booked, since the registry reads balances statically too).
contract WordFallback {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}

/// @dev Claim target whose fallback answers with fewer bytes than a word: not a balance, so a valid target.
contract ShortFallback {
    uint256 public calls;

    fallback(bytes calldata) external returns (bytes memory) {
        calls++;
        return hex"deadbeef";
    }
}

/// @dev Claim target whose fallback reverts on the `balanceOf` probe and succeeds on `claim()`.
contract RevertingFallback {
    uint256 public calls;

    fallback(bytes calldata data) external returns (bytes memory) {
        if (bytes4(data[:4]) != bytes4(keccak256("claim()"))) revert("not a token");
        calls++;
        return "";
    }
}

/// @dev Claim target that can be switched between a plain distributor and one that answers `balanceOf`.
contract SwitchableTarget {
    bool public answers;
    uint256 public calls;

    function setAnswers(bool value) external {
        answers = value;
    }

    function balanceOf(address) external view returns (uint256) {
        require(answers, "not a token");
        return 0;
    }

    function claim() external {
        calls++;
    }
}

/// @dev Adversarial edges on top of the lifecycle, rewards and signatures suites: inputs the implementation
///      did not necessarily consider (boundaries, second calls, callers that are not who the code assumed,
///      tokens and targets of the wrong kind) and cross-checks between the ERC-1271 answer and seat state.
/// forge-config: default.fuzz.runs = 512
contract SeatLeaseAdversarialTest is Base {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant FAIL = 0xffffffff;
    uint256 internal constant SECP256K1_N_DIV_2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    uint256 internal strangerKey;

    function setUp() public override {
        super.setUp();
        (stranger, strangerKey) = makeAddrAndKey("stranger");
        reward.mint(owner, 10_000e18);
        reward.mint(stranger, 10_000e18);
        reward.mint(address(distributor), 10_000e18);
        vm.deal(address(distributor), 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _depositSecondSeat(uint256 tokenId, address seatOwner, uint16 bps, address allowed) internal {
        nft.mint(seatOwner, tokenId);
        vm.startPrank(seatOwner);
        nft.approve(address(lease), tokenId);
        lease.deposit(tokenId, bps, SeatLease.Mode.Permissioned, allowed, 0, oracle, QUESTION, "second");
        vm.stopPrank();
    }

    function _creditReward(uint256 tokenId, address from, uint256 amount) internal {
        vm.startPrank(from);
        reward.approve(address(lease), amount);
        lease.credit(tokenId, address(reward), amount);
        vm.stopPrank();
    }

    function _signedBlob(uint256 key, uint256 tokenId, uint64 expiresAt)
        internal
        view
        returns (bytes32 digest, bytes memory blob)
    {
        SeatLease.WorkerAuthorization memory a = _auth(tokenId, expiresAt);
        digest = _workerDigest(a);
        blob = _encode1271(a, _sign(key, digest));
    }

    // ------------------------------------------------------------------ take / quit edges

    function test_take_permissionedWithZeroAllowedOperatorIsUntakeable() public {
        _deposit(5000, SeatLease.Mode.Permissioned, address(0), 0, oracle);
        address[3] memory callers = [owner, operator, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(SeatLease.NotAllowedOperator.selector, TOKEN_ID, callers[i]));
            lease.take(TOKEN_ID);
        }
    }

    function test_take_openRevertsWhenCallerCannotCoverBond() public {
        _depositOpen(5000);
        address poor = makeAddr("poor");
        vm.startPrank(poor);
        bond.approve(address(lease), BOND_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, BOND_AMOUNT));
        lease.take(TOKEN_ID);
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).operator, address(0));
    }

    function test_take_bondAmountRaisedWhileVacantAppliesToNextOperator() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), 2 * BOND_AMOUNT, oracle, QUESTION, "");
        _activateTerms();
        vm.startPrank(stranger);
        bond.approve(address(lease), 2 * BOND_AMOUNT);
        lease.take(TOKEN_ID);
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).bondHeld, 2 * BOND_AMOUNT);
        // The first operator's earlier bond has fully left the registry; only the new bond is held.
        assertEq(bond.balanceOf(address(lease)), 2 * BOND_AMOUNT);
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT);
    }

    function test_quit_twiceRevertsAndReturnsBondOnce() public {
        _depositOpen(5000);
        _takeOpen();
        vm.startPrank(operator);
        lease.quit(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotOperator.selector, TOKEN_ID, operator));
        lease.quit(TOKEN_ID);
        vm.stopPrank();
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT);
        assertEq(bond.balanceOf(address(lease)), 0);
    }

    function test_cut_twiceRevertsAndReturnsBondOnce() public {
        _depositOpen(5000);
        _takeOpen();
        vm.startPrank(owner);
        lease.cut(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatVacant.selector, TOKEN_ID));
        lease.cut(TOKEN_ID);
        vm.stopPrank();
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT);
    }

    function test_deposit_ownerOfOneSeatCannotDepositAnothersSeat() public {
        nft.mint(stranger, 8);
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, 8, owner));
        lease.deposit(8, 5000, SeatLease.Mode.Open, address(0), 0, oracle, QUESTION, "");
        vm.stopPrank();
        assertEq(nft.ownerOf(8), stranger);
    }

    function test_deposit_approvedOperatorOfNftCannotDepositForTheHolder() public {
        // An ERC-721 operator can move the token but is not its owner; deposit records msg.sender as owner,
        // so it must refuse anyone but the holder.
        vm.prank(owner);
        nft.setApprovalForAll(stranger, true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, stranger));
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), 0, oracle, QUESTION, "");
        assertEq(nft.ownerOf(TOKEN_ID), owner);
    }

    function test_nftTransferAfterDepositDoesNotChangeSeatOwner() public {
        // The seat's holder holds the token; the depositor keeps administering the seat even after selling
        // nothing (there is nothing to sell) and a second party cannot claim it.
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, stranger));
        lease.withdraw(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).owner, owner);
        assertEq(nft.ownerOf(TOKEN_ID), _holder());
    }

    // ------------------------------------------------------------------ credit edges

    function test_credit_cannotMoveTheDepositedSeatThroughTheErc20Path() public {
        // `IERC20.transferFrom` and `IERC721.transferFrom` share a selector, so `credit` with the seat NFT
        // as token would reach the NFT. The revision refuses the seat NFT before any call is made, for every
        // caller, so the seat in custody can never be moved through this path.
        _depositOpen(5000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, address(nft)));
        lease.credit(TOKEN_ID, address(nft), TOKEN_ID);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, address(nft)));
        lease.credit(TOKEN_ID, address(nft), TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), _holder());
        assertEq(lease.credited(TOKEN_ID, address(nft)), 0);
    }

    function test_credit_seatNftIsRefusedEvenWhenTheCallerOwnsAndApprovedAnotherSeat() public {
        // The refusal is by address, not by outcome: a caller who really could hand a second seat over through
        // the ERC-20 path is still refused, the second seat stays with them, nothing is booked and the NFT
        // collection remains a forbidden claim target (with or without a booked entry).
        _depositOpen(5000);
        nft.mint(stranger, 8);
        vm.startPrank(stranger);
        nft.approve(address(lease), 8);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, address(nft)));
        lease.credit(TOKEN_ID, address(nft), 8);
        vm.stopPrank();
        assertEq(nft.ownerOf(8), stranger);
        assertEq(nft.getApproved(8), address(lease));
        assertEq(lease.credited(TOKEN_ID, address(nft)), 0);
        assertEq(lease.totalCredited(address(nft)), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(nft)));
        lease.claim(TOKEN_ID, address(nft), "", new address[](0));
        assertEq(nft.ownerOf(TOKEN_ID), _holder());
    }

    function test_credit_seatNftRefusalPrecedesTheValueChecks() public {
        // The NFT check runs after the deposit and zero-amount checks and before any value check, so the
        // error for the NFT is the same whether or not ETH is attached; an undeposited seat still fails first.
        _depositOpen(5000);
        vm.deal(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, address(nft)));
        lease.credit{value: 1}(TOKEN_ID, address(nft), 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ZeroAmount.selector));
        lease.credit(TOKEN_ID, address(nft), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, 8));
        lease.credit(8, address(nft), 8);
    }

    function test_credit_toOneSeatDoesNotTouchAnother() public {
        _depositOpen(5000);
        _depositSecondSeat(8, stranger, 0, operator);
        _creditReward(TOKEN_ID, stranger, 100);
        _creditReward(8, owner, 5);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 100);
        assertEq(lease.credited(8, address(reward)), 5);
        assertEq(lease.totalCredited(address(reward)), 105);
    }

    function test_credit_maxEthValueIsBooked() public {
        _depositOpen(5000);
        vm.deal(stranger, type(uint128).max);
        vm.prank(stranger);
        lease.credit{value: type(uint128).max}(TOKEN_ID, address(0), type(uint128).max);
        assertEq(lease.credited(TOKEN_ID, address(0)), type(uint128).max);
    }

    function test_receive_rejectsEthOutsideClaimEvenFromOwnerAndOperator() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(owner);
        (bool ok,) = address(lease).call{value: 1}("");
        assertFalse(ok);
        vm.prank(operator);
        (ok,) = address(lease).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(lease).balance, 0);
    }

    // ------------------------------------------------------------------ claim edges

    function test_claim_listedAddressWithoutCodeReverts() public {
        _depositOpen(5000);
        address[] memory tokens = new address[](1);
        tokens[0] = stranger;
        vm.prank(owner);
        vm.expectRevert();
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
    }

    function test_claim_refusesEveryTargetWithoutCode() public {
        // An EOA, a precompile (which has no code even though it answers calls), the zero address and an
        // address whose contract has not been deployed yet are all refused before the call is made. A
        // vacuous claim against such an address could otherwise be used as a free `claim` that books
        // pre-existing dust.
        _depositOpen(5000);
        reward.mint(address(lease), 7); // unbooked dust the vacuous claim must not book
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        address[4] memory targets = [stranger, address(4), address(0), vm.computeCreateAddress(stranger, 99)];
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, targets[i]));
            lease.claim(TOKEN_ID, targets[i], hex"", tokens);
        }
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0);
    }

    function test_claim_refusesTargetWhoseFallbackAnswersWithAWord() public {
        // The token guard is "answers balanceOf(this) with at least one word". A contract with a catch-all
        // fallback that returns a word looks like a token to the registry and is refused, even though it never
        // declared `balanceOf`, so no `approve` could ever be routed through it.
        _depositOpen(5000);
        WordFallback target = new WordFallback();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(target)));
        lease.claim(TOKEN_ID, address(target), abi.encodeWithSignature("claim()"), new address[](0));
    }

    function test_claim_allowsTargetWhoseFallbackAnswersShortOrReverts() public {
        // Boundary of the guard: an answer shorter than a word is not a balance, and a revert is not an answer.
        // Such a target is a valid distributor; the call goes through and nothing is booked because nothing
        // arrived.
        _depositOpen(5000);
        ShortFallback shortTarget = new ShortFallback();
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.Claimed(TOKEN_ID, address(shortTarget), abi.encodeWithSignature("claim()"));
        lease.claim(TOKEN_ID, address(shortTarget), abi.encodeWithSignature("claim()"), new address[](0));
        assertEq(shortTarget.calls(), 1);

        RevertingFallback revertingTarget = new RevertingFallback();
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.Claimed(TOKEN_ID, address(revertingTarget), abi.encodeWithSignature("claim()"));
        lease.claim(TOKEN_ID, address(revertingTarget), abi.encodeWithSignature("claim()"), new address[](0));
        assertEq(revertingTarget.calls(), 1);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0);
    }

    function test_claim_targetGuardIsEvaluatedFreshOnEveryCall() public {
        // A target that was a valid distributor and later starts answering `balanceOf` is refused from then on:
        // the guard is a live probe, not a cached allow-list.
        _depositOpen(5000);
        SwitchableTarget target = new SwitchableTarget();
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(target), abi.encodeCall(SwitchableTarget.claim, ()), new address[](0));
        target.setAnswers(true);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(target)));
        lease.claim(TOKEN_ID, address(target), abi.encodeCall(SwitchableTarget.claim, ()), new address[](0));
        target.setAnswers(false);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(target), abi.encodeCall(SwitchableTarget.claim, ()), new address[](0));
        assertEq(target.calls(), 2);
    }

    function test_claim_bondTokenRewardIsBookedApartFromHeldBond() public {
        _depositOpen(5000);
        _takeOpen();
        BondPayingDistributor payer = new BondPayingDistributor(bond);
        bond.mint(address(payer), 40);
        address[] memory tokens = new address[](1);
        tokens[0] = address(bond);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(payer), abi.encodeCall(BondPayingDistributor.claim, (40)), tokens);
        assertEq(lease.credited(TOKEN_ID, address(bond)), 40);
        assertEq(lease.seat(TOKEN_ID).bondHeld, BOND_AMOUNT);
        lease.sweep(TOKEN_ID, address(bond));
        assertEq(bond.balanceOf(owner), 20);
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT - BOND_AMOUNT + 20);
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT + 20);
        assertEq(bond.balanceOf(address(lease)), 0);
    }

    function test_claim_listingTheNftCollectionRevertsBeforeTheTargetIsCalled() public {
        // The NFT collection is refused in the pre-call loop wherever it appears in `tokens`, so the distributor
        // is never reached and its reward stays where it was.
        _depositOpen(5000);
        distributor.setReward(_holder(), 1_000, 1);
        uint256 distributorReward = reward.balanceOf(address(distributor));
        for (uint256 pos; pos < 3; ++pos) {
            address[] memory tokens = new address[](3);
            tokens[0] = address(reward);
            tokens[1] = address(0);
            tokens[2] = address(reward);
            tokens[pos] = address(nft);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, address(nft)));
            lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        }
        assertEq(reward.balanceOf(address(distributor)), distributorReward);
        assertEq(lease.credited(TOKEN_ID, address(nft)), 0);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0);
    }

    function testFuzz_claim_repeatedListingsBookTheGainOnce(uint8 repeats, uint96 tokenAmount, uint96 ethAmount)
        public
    {
        // However many times the reward token and ETH are listed, and in whatever interleaving, exactly the
        // gain is booked and the registry stays solvent for the token.
        repeats = uint8(bound(repeats, 1, 12));
        tokenAmount = uint96(bound(tokenAmount, 0, 10_000e18));
        ethAmount = uint96(bound(ethAmount, 0, 10 ether));
        _depositOpen(5000);
        distributor.setReward(_holder(), tokenAmount, ethAmount);
        address[] memory tokens = new address[](2 * uint256(repeats));
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i] = i % 2 == 0 ? address(reward) : address(0);
        }
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), tokenAmount);
        assertEq(lease.credited(TOKEN_ID, address(0)), ethAmount);
        assertEq(lease.totalCredited(address(reward)), reward.balanceOf(address(lease)));
        assertEq(lease.totalCredited(address(0)), address(lease).balance);
    }

    function test_claim_duplicateListingsDoNotHideADecrease() public {
        // The skip for a repeated entry applies only to booking. A listed balance that fell during the call is
        // still caught on its first entry, even when that entry is repeated later in the list.
        _depositOpen(5000);
        TunableToken t = new TunableToken();
        t.mint(_holder(), 5);
        Burner burner = new Burner();
        address[] memory tokens = new address[](3);
        tokens[0] = address(t);
        tokens[1] = address(reward);
        tokens[2] = address(t);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.HolderBalanceDecreased.selector, address(t), 5, 0));
        lease.claim(TOKEN_ID, address(burner), abi.encodeCall(Burner.burn, (t, 5)), tokens);
        assertEq(t.balanceOf(_holder()), 5, "failed claim must roll back the burn");
        assertEq(lease.credited(TOKEN_ID, address(t)), 0);
    }

    function test_claim_ownerOfAnotherSeatCannotClaimForThisOne() public {
        _depositOpen(5000);
        _depositSecondSeat(8, stranger, 0, operator);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, stranger));
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), new address[](0));
    }

    function test_claim_rewardIsBookedToTheClaimingSeatOnly() public {
        _depositOpen(5000);
        _depositSecondSeat(8, stranger, 0, operator);
        distributor.setReward(lease.holderOf(8), 1_000, 1);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        vm.prank(stranger);
        lease.claim(8, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(8, address(reward)), 1_000);
        assertEq(lease.credited(8, address(0)), 1);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0);
    }

    function test_claim_reentryIntoTakeDepositRedeemAndOracleCutIsBlocked() public {
        _depositOpen(5000);
        ReentrantDistributor re = new ReentrantDistributor(address(lease));
        bytes memory expected = abi.encodeWithSelector(
            SeatLease.ClaimFailed.selector,
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes[] memory payloads = new bytes[](4);
        payloads[0] = abi.encodeCall(SeatLease.take, (TOKEN_ID));
        payloads[1] =
            abi.encodeCall(SeatLease.deposit, (8, 0, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), ""));
        payloads[2] = abi.encodeCall(SeatLease.redeemBond, ());
        payloads[3] = abi.encodeCall(SeatLease.cutByOracle, (TOKEN_ID, att, _signAttestation(oracleKey, att)));
        for (uint256 i; i < payloads.length; ++i) {
            re.setPayload(payloads[i]);
            vm.prank(owner);
            vm.expectRevert(expected);
            lease.claim(TOKEN_ID, address(re), abi.encodeCall(ReentrantDistributor.claim, ()), new address[](0));
        }
    }

    function test_claim_targetCannotSetTermsDuringClaim() public {
        // An unrelated claim target cannot change this seat's terms, even during the owner's claim.
        _depositOpen(5000);
        ReentrantDistributor re = new ReentrantDistributor(address(lease));
        re.setPayload(
            abi.encodeCall(
                SeatLease.setTerms, (TOKEN_ID, 0, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "")
            )
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SeatLease.ClaimFailed.selector,
                abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, address(re))
            )
        );
        lease.claim(TOKEN_ID, address(re), abi.encodeCall(ReentrantDistributor.claim, ()), new address[](0));
        assertEq(lease.seat(TOKEN_ID).ownerBps, 5000);
    }

    function test_claim_targetCannotInvokeHolderReceiverHook() public {
        _depositOpen(5000);
        ReentrantDistributor re = new ReentrantDistributor(_holder());
        re.setPayload(abi.encodeCall(SeatHolder.onERC721Received, (address(0), address(0), 8, "")));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SeatLease.ClaimFailed.selector,
                abi.encodeWithSelector(SeatHolder.UnexpectedToken.selector, address(re), 8)
            )
        );
        lease.claim(TOKEN_ID, address(re), abi.encodeCall(ReentrantDistributor.claim, ()), new address[](0));
    }

    function test_claim_receiveWindowClosesAfterAFailedClaim() public {
        _depositOpen(5000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ClaimFailed.selector, bytes("")));
        lease.claim(TOKEN_ID, address(distributor), abi.encodeWithSignature("nope()"), new address[](0));
        vm.prank(stranger);
        (bool ok,) = address(lease).call{value: 1}("");
        assertFalse(ok);
    }

    function test_claim_secondClaimBooksOnlyTheNewGain() public {
        _depositOpen(5000);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        bytes memory data = abi.encodeCall(MockDistributor.claim, ());
        distributor.setReward(_holder(), 100, 0);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), data, tokens);
        // Nothing new to pay: the second claim must not re-book the balance already held.
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), data, tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 100);
        distributor.setReward(_holder(), 7, 0);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), data, tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 107);
        assertEq(reward.balanceOf(address(lease)), 107);
    }

    // ------------------------------------------------------------------ sweep edges

    function test_sweep_oneWeiAtHalfGoesToOperator() public {
        _depositOpen(5000);
        _takeOpen();
        _creditReward(TOKEN_ID, stranger, 1);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(operator), 1);
        assertEq(reward.balanceOf(owner), 10_000e18);
    }

    function test_sweep_oneBpsOnSmallAmountPaysOwnerNothing() public {
        _depositOpen(1);
        _takeOpen();
        _creditReward(TOKEN_ID, stranger, 9_999);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 10_000e18);
        assertEq(reward.balanceOf(operator), 9_999);
    }

    function test_sweep_afterOracleCutPreservesOperatorsBookedShare() public {
        _depositOpen(0);
        _takeOpen();
        _creditReward(TOKEN_ID, stranger, 1_000);
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
        // The forfeiture is the bond; already booked rewards still belong to the cut operator.
        _creditReward(TOKEN_ID, stranger, 7);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 10_000e18 + 7);
        assertEq(reward.balanceOf(operator), 0);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 1_000);
        lease.sweepFor(TOKEN_ID, address(reward), operator);
        assertEq(reward.balanceOf(operator), 1_000);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
    }

    function test_sweep_twiceRevertsSecondTime() public {
        _depositOpen(5000);
        _creditReward(TOKEN_ID, stranger, 10);
        lease.sweep(TOKEN_ID, address(reward));
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.sweep(TOKEN_ID, address(reward));
    }

    function test_sweep_oneSeatLeavesTheOtherSeatsBalanceIntact() public {
        _depositOpen(5000);
        _depositSecondSeat(8, stranger, 10_000, operator);
        _creditReward(TOKEN_ID, stranger, 300);
        _creditReward(8, owner, 200);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(lease.credited(8, address(reward)), 200);
        assertEq(lease.totalCredited(address(reward)), 200);
        assertEq(reward.balanceOf(address(lease)), 200);
        lease.sweep(8, address(reward));
        assertEq(reward.balanceOf(address(lease)), 0);
    }

    function test_sweep_preservesBookingAcrossTermChanges() public {
        _depositOpen(10_000);
        _creditReward(TOKEN_ID, stranger, 100);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 0, SeatLease.Mode.Permissioned, operator, 0, oracle, QUESTION, "");
        _activateTerms();
        _takePermissioned();
        _creditReward(TOKEN_ID, stranger, 7);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 10_000e18 + 100);
        assertEq(reward.balanceOf(operator), 7);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
    }

    function test_sweep_operatorWhoQuitCanCollectItsEarlierShare() public {
        _depositOpen(0);
        _takeOpen();
        _creditReward(TOKEN_ID, stranger, 100);
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(operator), 0);
        assertEq(reward.balanceOf(owner), 10_000e18);
        lease.sweepFor(TOKEN_ID, address(reward), operator);
        assertEq(reward.balanceOf(operator), 100);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
    }

    // ------------------------------------------------------------------ cutByOracle edges

    function test_cutByOracle_requestIdIsConsumedGloballyAcrossSeats() public {
        _depositOpen(5000);
        _takeOpen();
        _depositSecondSeat(8, stranger, 5000, operator);
        vm.prank(operator);
        lease.take(8);
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes memory sig = _signAttestation(oracleKey, att);
        lease.cutByOracle(8, att, sig);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleRequestUsed.selector, att.requestId));
        lease.cutByOracle(TOKEN_ID, att, sig);
        assertEq(lease.seat(TOKEN_ID).operator, operator);
    }

    function test_cutByOracle_rotatedSignerInvalidatesOldAttestations() public {
        _depositOpen(5000);
        (address newOracle,) = makeAddrAndKey("new-oracle");
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, newOracle, QUESTION, "");
        _activateTerms();
        _takeOpen();
        // Keep the attestation fresh so this exercises signer rotation rather than tenure/expiry guards.
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes memory sig = _signAttestation(oracleKey, att);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleSignerMismatch.selector, newOracle, oracle));
        lease.cutByOracle(TOKEN_ID, att, sig);
    }

    function test_cutByOracle_rejectsSignatureUnderWorkerDomain() public {
        _depositOpen(5000);
        _takeOpen();
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes32 wrongDomain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(WORKER_NAME)),
                keccak256(bytes(WORKER_VERSION)),
                block.chainid,
                address(nft)
            )
        );
        bytes32 structHash = keccak256(abi.encode(lease.ORACLE_ATTESTATION_TYPEHASH(), att.requestId));
        bytes memory sig = _sign(oracleKey, keccak256(abi.encodePacked("\x19\x01", wrongDomain, structHash)));
        address recovered = ECDSA.recover(lease.hashOracleAttestation(att), sig);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleSignerMismatch.selector, oracle, recovered));
        lease.cutByOracle(TOKEN_ID, att, sig);
    }

    function test_cutByOracle_rejectsMalleableSignature() public {
        _depositOpen(5000);
        _takeOpen();
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oracleKey, _oracleDigest(att));
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(uint256(n) - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        lease.cutByOracle(TOKEN_ID, att, abi.encodePacked(r, sHigh, v == 27 ? uint8(28) : uint8(27)));
        assertEq(lease.seat(TOKEN_ID).operator, operator);
    }

    function test_cutByOracle_checksExpiryBeforeSignature() public {
        _depositOpen(5000);
        _takeOpen();
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        att.expiresAt = 0;
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleAttestationExpired.selector, uint64(0)));
        lease.cutByOracle(TOKEN_ID, att, hex"");
    }

    function test_cutByOracle_escrowsForfeitedBondWhenOwnerCannotReceive() public {
        TunableToken t = new TunableToken();
        SeatLease l = new SeatLease(address(nft), address(t), WORKER_NAME, WORKER_VERSION);
        t.mint(operator, BOND_AMOUNT);
        vm.startPrank(owner);
        nft.approve(address(l), TOKEN_ID);
        l.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        vm.stopPrank();
        vm.startPrank(operator);
        t.approve(address(l), BOND_AMOUNT);
        l.take(TOKEN_ID);
        vm.stopPrank();
        t.setBehaviour(owner, TunableToken.Behaviour.Revert);

        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes memory sig = _sign(oracleKey, l.hashOracleAttestation(att));
        vm.expectEmit(address(l));
        emit SeatLease.BondEscrowed(owner, BOND_AMOUNT);
        l.cutByOracle(TOKEN_ID, att, sig);
        assertEq(l.bondOwed(owner), BOND_AMOUNT);
        assertEq(l.bondOwed(operator), 0);
        assertEq(l.seat(TOKEN_ID).operator, address(0));

        // The operator, whose bond was forfeited, has nothing to redeem.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NothingOwed.selector, operator));
        l.redeemBond();

        t.setBehaviour(owner, TunableToken.Behaviour.Normal);
        vm.prank(owner);
        l.redeemBond();
        assertEq(t.balanceOf(owner), BOND_AMOUNT);
    }

    function test_redeemBond_twiceRevertsSecondTime() public {
        TunableToken t = new TunableToken();
        SeatLease l = new SeatLease(address(nft), address(t), WORKER_NAME, WORKER_VERSION);
        t.mint(operator, BOND_AMOUNT);
        vm.startPrank(owner);
        nft.approve(address(l), TOKEN_ID);
        l.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        vm.stopPrank();
        vm.startPrank(operator);
        t.approve(address(l), BOND_AMOUNT);
        l.take(TOKEN_ID);
        vm.stopPrank();
        t.setBehaviour(operator, TunableToken.Behaviour.ReturnFalse);
        vm.prank(operator);
        l.quit(TOKEN_ID);
        t.setBehaviour(operator, TunableToken.Behaviour.Normal);
        vm.startPrank(operator);
        l.redeemBond();
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NothingOwed.selector, operator));
        l.redeemBond();
        vm.stopPrank();
        assertEq(t.balanceOf(operator), BOND_AMOUNT);
    }

    // ------------------------------------------------------------------ isValidSignature edges

    function test_isValidSignature_followsOperatorChanges() public {
        _depositOpen(5000);
        _takeOpen();
        uint64 expiry = uint64(block.timestamp + 1 days);
        (bytes32 digest, bytes memory byOperator) = _signedBlob(operatorKey, TOKEN_ID, expiry);
        (, bytes memory byStranger) = _signedBlob(strangerKey, TOKEN_ID, expiry);
        assertEq(lease.isValidSignature(digest, byOperator), MAGIC);
        assertEq(lease.isValidSignature(digest, byStranger), FAIL);

        vm.prank(operator);
        lease.quit(TOKEN_ID);
        assertEq(lease.isValidSignature(digest, byOperator), FAIL);

        vm.startPrank(stranger);
        bond.approve(address(lease), BOND_AMOUNT);
        lease.take(TOKEN_ID);
        vm.stopPrank();
        assertEq(lease.isValidSignature(digest, byOperator), FAIL);
        assertEq(lease.isValidSignature(digest, byStranger), MAGIC);

        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
        assertEq(lease.isValidSignature(digest, byStranger), FAIL);
    }

    function test_isValidSignature_rejectsAtExactExpiry() public {
        _depositOpen(5000);
        _takeOpen();
        (bytes32 digest, bytes memory blob) = _signedBlob(operatorKey, TOKEN_ID, uint64(block.timestamp));
        assertEq(lease.isValidSignature(digest, blob), FAIL);
        (digest, blob) = _signedBlob(operatorKey, TOKEN_ID, uint64(block.timestamp + 1));
        assertEq(lease.isValidSignature(digest, blob), MAGIC);
    }

    function test_isValidSignature_rejectsWalletOfAnotherRegistryOverTheSameNft() public {
        _depositOpen(5000);
        _takeOpen();
        SeatLease other = new SeatLease(address(nft), address(bond), WORKER_NAME, WORKER_VERSION);
        uint64 expiry = uint64(block.timestamp + 1 days);
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        a.wallet = address(other);
        bytes32 digest = _workerDigest(a);
        bytes memory blob = _encode1271(a, _sign(operatorKey, digest));
        // Same NFT domain, same digest on both registries; only the named wallet may accept it, and that
        // registry has no operator for the seat.
        assertEq(lease.isValidSignature(digest, blob), FAIL);
        assertEq(other.isValidSignature(digest, blob), FAIL);
    }

    function test_isValidSignature_rejectsFieldTamperedAfterSigning() public {
        _depositOpen(5000);
        _takeOpen();
        uint64 expiry = uint64(block.timestamp + 1 days);
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        bytes32 digest = _workerDigest(a);
        bytes memory sig = _sign(operatorKey, digest);

        SeatLease.WorkerAuthorization memory t = a;
        t.relayOrigin = "https://evil.example";
        assertEq(lease.isValidSignature(digest, _encode1271(t, sig)), FAIL);
        assertEq(lease.isValidSignature(_workerDigest(t), _encode1271(t, sig)), FAIL);

        t = a;
        t.nonce = keccak256("other nonce");
        assertEq(lease.isValidSignature(digest, _encode1271(t, sig)), FAIL);
        assertEq(lease.isValidSignature(_workerDigest(t), _encode1271(t, sig)), FAIL);

        t = a;
        t.deviceKey = keccak256("attacker device");
        assertEq(lease.isValidSignature(digest, _encode1271(t, sig)), FAIL);
        assertEq(lease.isValidSignature(_workerDigest(t), _encode1271(t, sig)), FAIL);

        t = a;
        t.expiresAt = expiry + 1 days;
        assertEq(lease.isValidSignature(digest, _encode1271(t, sig)), FAIL);
        assertEq(lease.isValidSignature(_workerDigest(t), _encode1271(t, sig)), FAIL);
    }

    function test_isValidSignature_rejectsDirtyHighBitsInStaticWords() public {
        // A blob whose decoded values equal a valid authorization but whose static words carry bits outside the
        // declared type (padding of the address, of the uint64 expiry) is not the canonical encoding and must
        // fail rather than be accepted as the same authorization. Flipping a bit inside the value range fails
        // too, as the digest no longer matches.
        _depositOpen(5000);
        _takeOpen();
        (bytes32 digest, bytes memory blob) = _signedBlob(operatorKey, TOKEN_ID, uint64(block.timestamp + 1 days));
        assertEq(lease.isValidSignature(digest, blob), MAGIC);

        // Word 1 is the wallet: byte 32 is its highest padding byte.
        bytes memory dirtyWallet = _copy(blob);
        dirtyWallet[32] = 0x01;
        assertEq(lease.isValidSignature(digest, dirtyWallet), FAIL);

        // Word 4 is expiresAt: byte 128 is its highest padding byte.
        bytes memory dirtyExpiry = _copy(blob);
        dirtyExpiry[4 * 32] = 0x01;
        assertEq(lease.isValidSignature(digest, dirtyExpiry), FAIL);

        // Word 2 is the tokenId: flip its lowest byte, which is a valid but different tokenId.
        bytes memory otherSeat = _copy(blob);
        otherSeat[3 * 32 - 1] ^= 0x01;
        assertEq(lease.isValidSignature(digest, otherSeat), FAIL);

        // Every mutated blob is refused by the decoder or the digest check; the untouched blob still pairs.
        assertEq(lease.isValidSignature(digest, blob), MAGIC);
    }

    function _copy(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length);
        for (uint256 i; i < data.length; ++i) {
            out[i] = data[i];
        }
    }

    function test_isValidSignature_rejectsCompactAndZeroSignatures() public {
        _depositOpen(5000);
        _takeOpen();
        uint64 expiry = uint64(block.timestamp + 1 days);
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        bytes32 digest = _workerDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, digest);
        // EIP-2098 64-byte form is not accepted; only the 65-byte r||s||v form pairs a device.
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        assertEq(lease.isValidSignature(digest, _encode1271(a, abi.encodePacked(r, vs))), FAIL);
        // v outside {27, 28}.
        assertEq(lease.isValidSignature(digest, _encode1271(a, abi.encodePacked(r, s, uint8(0)))), FAIL);
        assertEq(lease.isValidSignature(digest, _encode1271(a, abi.encodePacked(r, s, uint8(1)))), FAIL);
        // All zero: ecrecover returns address(0), which is never an operator.
        assertEq(lease.isValidSignature(digest, _encode1271(a, new bytes(65))), FAIL);
    }

    function test_isValidSignature_ownerSignatureNeverPairsEvenWhenOwnerOperates() public {
        // The owner may operate its own seat only through take(); an unrelated owner key never pairs.
        (address ownerAsOperator, uint256 ownerAsOperatorKey) = makeAddrAndKey("owner-operator");
        nft.mint(ownerAsOperator, 8);
        vm.startPrank(ownerAsOperator);
        nft.approve(address(lease), 8);
        lease.deposit(8, 5000, SeatLease.Mode.Permissioned, ownerAsOperator, 0, oracle, QUESTION, "");
        vm.stopPrank();
        uint64 expiry = uint64(block.timestamp + 1 days);
        (bytes32 digest, bytes memory blob) = _signedBlob(ownerAsOperatorKey, 8, expiry);
        assertEq(lease.isValidSignature(digest, blob), FAIL);
        vm.prank(ownerAsOperator);
        lease.take(8);
        assertEq(lease.isValidSignature(digest, blob), MAGIC);
    }

    function test_isValidSignature_isPureOfCallerAndSeatOwner() public {
        _depositOpen(5000);
        _takeOpen();
        (bytes32 digest, bytes memory blob) = _signedBlob(operatorKey, TOKEN_ID, uint64(block.timestamp + 1));
        address[3] memory callers = [owner, operator, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            assertEq(lease.isValidSignature(digest, blob), MAGIC);
        }
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_isValidSignature_onlyTheNamedSeatPairs(uint256 tokenId) public {
        _depositOpen(5000);
        _takeOpen();
        (bytes32 digest, bytes memory blob) = _signedBlob(operatorKey, tokenId, uint64(block.timestamp + 1));
        assertEq(lease.isValidSignature(digest, blob), tokenId == TOKEN_ID ? MAGIC : FAIL);
    }

    function testFuzz_isValidSignature_expiryBoundary(uint64 expiresAt, uint64 now_) public {
        now_ = uint64(bound(now_, 1, type(uint64).max - 1));
        _depositOpen(5000);
        _takeOpen();
        vm.warp(now_);
        (bytes32 digest, bytes memory blob) = _signedBlob(operatorKey, TOKEN_ID, expiresAt);
        assertEq(lease.isValidSignature(digest, blob), expiresAt > now_ ? MAGIC : FAIL);
    }

    function testFuzz_isValidSignature_forgedOperatorSignatureNeverPasses(bytes32 r, bytes32 s, uint8 v) public {
        _depositOpen(5000);
        _takeOpen();
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, uint64(block.timestamp + 1));
        bytes32 digest = _workerDigest(a);
        // A forged (r, s, v) recovering to the operator would be an ECDSA break; every other outcome fails.
        (address recovered,,) = ECDSA.tryRecover(digest, abi.encodePacked(r, s, v));
        bytes4 result = lease.isValidSignature(digest, _encode1271(a, abi.encodePacked(r, s, v)));
        assertEq(result, recovered == operator ? MAGIC : FAIL);
        assertTrue(recovered != operator || uint256(s) <= SECP256K1_N_DIV_2);
    }

    function testFuzz_cutByOracle_chainAndQuestionMustMatch(uint256 chainId, bytes32 questionHash) public {
        _depositOpen(5000);
        _takeOpen();
        SeatLease.OracleAttestation memory att =
            _attestation(keccak256("req"), questionHash, lease.ANSWER_TYPE_BOOL(), abi.encode(true));
        att.chainId = chainId;
        bytes memory sig = _signAttestation(oracleKey, att);
        if (chainId != block.chainid) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleChainMismatch.selector, block.chainid, chainId));
        } else if (questionHash != QUESTION) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleQuestionMismatch.selector, QUESTION, questionHash));
        }
        lease.cutByOracle(TOKEN_ID, att, sig);
        bool cut = chainId == block.chainid && questionHash == QUESTION;
        assertEq(lease.seat(TOKEN_ID).operator, cut ? address(0) : operator);
        assertEq(bond.balanceOf(owner), cut ? BOND_AMOUNT : 0);
    }

    function testFuzz_cutByOracle_expiryBoundary(uint64 expiresAt, uint64 now_) public {
        now_ = uint64(bound(now_, 1, type(uint64).max - 1));
        vm.warp(now_);
        _depositOpen(5000);
        _takeOpen();
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        att.expiresAt = expiresAt;
        bytes memory sig = _signAttestation(oracleKey, att);
        if (expiresAt <= now_) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleAttestationExpired.selector, expiresAt));
        }
        lease.cutByOracle(TOKEN_ID, att, sig);
    }

    function testFuzz_cutByOracle_answerMustBeExactlyTrue(bytes calldata answer, uint8 answerType) public {
        _depositOpen(5000);
        _takeOpen();
        SeatLease.OracleAttestation memory att = _attestation(keccak256("req"), QUESTION, answerType, answer);
        bytes memory sig = _signAttestation(oracleKey, att);
        bool isTrue = answer.length == 32 && abi.decode(answer, (uint256)) == 1;
        if (answerType != 1) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleAnswerNotBool.selector, answerType));
        } else if (!isTrue) {
            vm.expectRevert(SeatLease.OracleAnswerNotTrue.selector);
        }
        lease.cutByOracle(TOKEN_ID, att, sig);
        assertEq(lease.seat(TOKEN_ID).operator, answerType == 1 && isTrue ? address(0) : operator);
    }

    function testFuzz_cutByOracle_anyCallerMaySubmit(address caller) public {
        vm.assume(caller != address(lease));
        _depositOpen(5000);
        _takeOpen();
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        uint256 callerBalanceBefore = bond.balanceOf(caller);
        vm.prank(caller);
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
        assertEq(lease.seat(TOKEN_ID).operator, address(0));
        assertEq(bond.balanceOf(owner), BOND_AMOUNT);
        assertEq(bond.balanceOf(caller), callerBalanceBefore + (caller == owner ? BOND_AMOUNT : 0));
    }

    function testFuzz_take_openBondRoundTripForAnyTaker(address taker, uint256 bondAmount) public {
        vm.assume(taker != address(0) && taker != address(lease) && taker.code.length == 0);
        bondAmount = bound(bondAmount, 0, type(uint128).max);
        _deposit(5000, SeatLease.Mode.Open, address(0), bondAmount, oracle);
        bond.mint(taker, bondAmount);
        uint256 before = bond.balanceOf(taker);
        vm.startPrank(taker);
        bond.approve(address(lease), bondAmount);
        lease.take(TOKEN_ID);
        assertEq(bond.balanceOf(taker), before - bondAmount);
        assertEq(lease.seat(TOKEN_ID).bondHeld, bondAmount);
        lease.quit(TOKEN_ID);
        vm.stopPrank();
        assertEq(bond.balanceOf(taker), before);
        assertEq(bond.balanceOf(address(lease)), 0);
    }

    function testFuzz_take_permissionedOnlyAllowedCaller(address allowed, address caller) public {
        vm.assume(allowed != address(0) && caller != address(0));
        vm.assume(allowed != address(lease) && caller != address(lease));
        _deposit(5000, SeatLease.Mode.Permissioned, allowed, BOND_AMOUNT, oracle);
        vm.prank(caller);
        if (caller != allowed) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.NotAllowedOperator.selector, TOKEN_ID, caller));
        }
        lease.take(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).operator, caller == allowed ? allowed : address(0));
        assertEq(lease.seat(TOKEN_ID).bondHeld, 0);
    }

    function testFuzz_sweep_twoSeatsConserveTheirOwnBalances(uint16 bps1, uint16 bps2, uint96 a1, uint96 a2) public {
        bps1 = uint16(bound(bps1, 0, 10_000));
        bps2 = uint16(bound(bps2, 0, 10_000));
        a1 = uint96(bound(a1, 1, type(uint96).max));
        a2 = uint96(bound(a2, 1, type(uint96).max));
        _depositOpen(bps1);
        _takeOpen();
        address owner2 = makeAddr("owner2");
        _depositSecondSeat(8, owner2, bps2, stranger);
        vm.prank(stranger);
        lease.take(8);

        reward.mint(stranger, uint256(a1) + a2);
        _creditReward(TOKEN_ID, stranger, a1);
        _creditReward(8, stranger, a2);

        uint256 ownerBefore = reward.balanceOf(owner);
        uint256 operatorBefore = reward.balanceOf(operator);
        uint256 strangerBefore = reward.balanceOf(stranger);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner) - ownerBefore, (uint256(a1) * bps1) / 10_000);
        assertEq(reward.balanceOf(operator) - operatorBefore, a1 - (uint256(a1) * bps1) / 10_000);
        assertEq(lease.credited(8, address(reward)), a2);
        assertEq(reward.balanceOf(address(lease)), a2);

        lease.sweep(8, address(reward));
        assertEq(reward.balanceOf(owner2), (uint256(a2) * bps2) / 10_000);
        assertEq(reward.balanceOf(stranger) - strangerBefore, a2 - (uint256(a2) * bps2) / 10_000);
        assertEq(reward.balanceOf(address(lease)), 0);
        assertEq(lease.totalCredited(address(reward)), 0);
    }

    function testFuzz_sweep_vacantPaysOwnerRegardlessOfBps(uint16 bps, uint96 amount, bool eth) public {
        bps = uint16(bound(bps, 0, 10_000));
        amount = uint96(bound(amount, 1, type(uint96).max));
        _depositOpen(bps);
        address token = eth ? address(0) : address(reward);
        if (eth) {
            vm.deal(stranger, amount);
            vm.prank(stranger);
            lease.credit{value: amount}(TOKEN_ID, address(0), amount);
        } else {
            reward.mint(stranger, amount);
            _creditReward(TOKEN_ID, stranger, amount);
        }
        uint256 before = eth ? owner.balance : reward.balanceOf(owner);
        lease.sweep(TOKEN_ID, token);
        uint256 afterwards = eth ? owner.balance : reward.balanceOf(owner);
        assertEq(afterwards - before, amount);
        assertEq(lease.credited(TOKEN_ID, token), 0);
    }

    function testFuzz_sweep_splitNeverLosesOrCreatesValue(uint16 bps, uint256 amount) public {
        bps = uint16(bound(bps, 0, 10_000));
        amount = bound(amount, 1, type(uint128).max);
        _depositOpen(bps);
        _takeOpen();
        reward.mint(stranger, amount);
        _creditReward(TOKEN_ID, stranger, amount);
        uint256 ownerBefore = reward.balanceOf(owner);
        uint256 operatorBefore = reward.balanceOf(operator);
        lease.sweep(TOKEN_ID, address(reward));
        uint256 ownerGain = reward.balanceOf(owner) - ownerBefore;
        uint256 operatorGain = reward.balanceOf(operator) - operatorBefore;
        assertEq(ownerGain + operatorGain, amount);
        assertLe(ownerGain, (amount * bps) / 10_000);
        assertGe(ownerGain + 1, (amount * bps) / 10_000);
        if (bps == 10_000) assertEq(operatorGain, 0);
        if (bps == 0) assertEq(ownerGain, 0);
    }

    function testFuzz_claim_booksExactlyWhatArrived(uint96 tokenAmount, uint96 ethAmount) public {
        tokenAmount = uint96(bound(tokenAmount, 0, 10_000e18));
        ethAmount = uint96(bound(ethAmount, 0, 10 ether));
        _depositOpen(5000);
        distributor.setReward(_holder(), tokenAmount, ethAmount);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), tokenAmount);
        assertEq(lease.credited(TOKEN_ID, address(0)), ethAmount);
        assertEq(reward.balanceOf(address(lease)), lease.totalCredited(address(reward)));
        assertEq(address(lease).balance, lease.totalCredited(address(0)));
    }

    function testFuzz_credit_requiresDepositedSeat(uint256 tokenId, uint96 amount) public {
        vm.assume(tokenId != TOKEN_ID);
        amount = uint96(bound(amount, 1, type(uint96).max));
        _depositOpen(5000);
        vm.deal(stranger, amount);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, tokenId));
        lease.credit{value: amount}(tokenId, address(0), amount);
        assertEq(address(lease).balance, 0);
    }

    function testFuzz_withdraw_onlyWhileVacantAndOnlyByOwner(address caller, bool occupied) public {
        vm.assume(caller != address(lease));
        _depositOpen(5000);
        if (occupied) _takeOpen();
        vm.prank(caller);
        if (caller != owner) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, caller));
        } else if (occupied) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotVacant.selector, TOKEN_ID));
        }
        lease.withdraw(TOKEN_ID);
        bool left = caller == owner && !occupied;
        assertEq(nft.ownerOf(TOKEN_ID), left ? owner : _holder());
    }
}
