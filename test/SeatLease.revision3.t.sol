// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./utils/Base.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {SeatHolder} from "../src/SeatHolder.sol";
import {MockDistributor} from "../src/mocks/MockDistributor.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {ClaimForDistributor, FeeOnTransferToken, ReentrantSweeper, TunableToken} from "./utils/Actors.sol";

contract HeavyRewardReceiver {
    uint256[8] public slots;

    receive() external payable {
        for (uint256 i; i < slots.length; ++i) {
            slots[i] = msg.value;
        }
    }
}

contract SettlementCallbackToken is MockERC20 {
    SeatLease private registry;
    bytes private payload;
    bool public attempted;
    bool public innerOk;

    constructor() MockERC20("Callback", "CALL") {}

    function arm(SeatLease lease_, bytes memory data) external {
        registry = lease_;
        payload = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        attempted = true;
        (innerOk,) = address(registry).call(payload);
        return super.transfer(to, amount);
    }
}

/// @dev Regressions for findings 327c1ca4, c8742c34 and the two documented operational limitations.
contract SeatLeaseRevision3Test is Base {
    function _tokens(address token) private pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token;
    }

    function _declareRewards() private {
        vm.prank(owner);
        lease.setRewardTokens(TOKEN_ID, _tokens(address(reward)));
        _activateTerms();
    }

    function _mature() private {
        vm.warp(uint256(lease.seat(TOKEN_ID).takenAt) + lease.TERMS_DELAY());
    }

    function _push(uint256 amount) private {
        reward.mint(_holder(), amount);
        vm.deal(_holder(), amount);
    }

    function _assertShares(address token, uint256 ownerAmount, uint256 operatorAmount) private view {
        assertEq(lease.share(TOKEN_ID, token, owner), ownerAmount);
        assertEq(lease.share(TOKEN_ID, token, operator), operatorAmount);
        assertEq(lease.credited(TOKEN_ID, token), ownerAmount + operatorAmount);
        assertEq(lease.totalCredited(token), ownerAmount + operatorAmount);
    }

    function testFuzz_takeSkimSweepQuitCannotTakeVacantRewards(uint16 bps, uint96 rawAmount, bool declared) public {
        bps = uint16(bound(bps, 0, 10_000));
        uint256 amount = bound(rawAmount, 1, 100 ether);
        _depositOpen(bps);
        if (declared) _declareRewards();
        _push(amount);
        uint256 ownerBefore = owner.balance;
        uint256 operatorBefore = operator.balance;
        _takeOpen();
        // ETH and declared tokens were already settled while vacant; undeclared tokens use the warm-up.
        if (!declared) lease.skim(TOKEN_ID, address(reward));
        lease.sweep(TOKEN_ID, address(0));
        lease.sweep(TOKEN_ID, address(reward));
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        assertEq(operator.balance, operatorBefore);
        assertEq(reward.balanceOf(operator), 0);
        assertEq(owner.balance - ownerBefore, amount);
        assertEq(reward.balanceOf(owner), amount);
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT);
    }

    function test_takeSettlesVacantBalancesEvenIfOperatorWaitsToSkim() public {
        _depositOpen(0);
        _declareRewards();
        _push(10 ether);
        _takeOpen();
        _mature();
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.skim(TOKEN_ID, address(reward));
        _assertShares(address(reward), 10 ether, 0);
        _assertShares(address(0), 10 ether, 0);
    }

    function testFuzz_exitSettlesUnderOutgoingSplit(uint16 bps, uint96 rawAmount, uint8 action) public {
        bps = uint16(bound(bps, 0, 10_000));
        uint256 amount = bound(rawAmount, 1, 100 ether);
        action = uint8(bound(action, 0, 2));
        _depositOpen(bps);
        _declareRewards();
        _takeOpen();
        _mature();
        _push(amount);
        if (action == 0) {
            vm.prank(operator);
            lease.quit(TOKEN_ID);
        } else if (action == 1) {
            vm.prank(owner);
            lease.cut(TOKEN_ID);
        } else {
            SeatLease.OracleAttestation memory a = _goodAttestation(keccak256("settle oracle"));
            lease.cutByOracle(TOKEN_ID, a, _signAttestation(oracleKey, a));
        }
        uint256 ownerPart = amount * bps / 10_000;
        _assertShares(address(reward), ownerPart, amount - ownerPart);
        _assertShares(address(0), ownerPart, amount - ownerPart);
        assertEq(lease.seat(TOKEN_ID).operator, address(0));
        assertEq(lease.seat(TOKEN_ID).bondHeld, 0);
        assertEq(bond.balanceOf(operator), action == 2 ? 9 * BOND_AMOUNT : 10 * BOND_AMOUNT);
        assertEq(bond.balanceOf(owner), action == 2 ? BOND_AMOUNT : 0);
        if (amount > ownerPart) {
            lease.sweepFor(TOKEN_ID, address(reward), operator);
            assertEq(reward.balanceOf(operator), amount - ownerPart);
        }
    }

    function test_permissionedCutThenSkimOrClaimCannotReassignHolderRewards() public {
        _depositPermissioned(5000);
        _declareRewards();
        _takePermissioned();
        _mature();
        _push(1000e18);
        vm.prank(owner);
        lease.cut(TOKEN_ID);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.skim(TOKEN_ID, address(reward));
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), _tokens(address(reward)));
        _assertShares(address(reward), 500e18, 500e18);
        _assertShares(address(0), 500e18, 500e18);
    }

    function test_warmupProtectsAccountKeyedClaimsAfterTake() public {
        _depositOpen(0);
        _declareRewards();
        ClaimForDistributor d = new ClaimForDistributor(reward);
        reward.mint(address(d), 10e18);
        vm.deal(address(d), 10 ether);
        _takeOpen();
        vm.prank(operator);
        d.claimFor(_holder(), 10e18, 10 ether);
        lease.skim(TOKEN_ID, address(reward));
        // Quit itself must also apply the warm-up to the unskimmed ETH.
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        _assertShares(address(reward), 10e18, 0);
        _assertShares(address(0), 10 ether, 0);
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT);
    }

    function test_claimAndSkimWarmupBoundaryAndRetakeResetsIt() public {
        _depositOpen(5000);
        _takeOpen();
        uint256 readyAt = uint256(lease.seat(TOKEN_ID).takenAt) + lease.TERMS_DELAY();
        reward.mint(address(distributor), 30);
        vm.warp(readyAt - 1);
        distributor.setReward(_holder(), 10, 0);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), _tokens(address(reward)));
        _assertShares(address(reward), 10, 0);
        vm.warp(readyAt);
        distributor.setReward(_holder(), 10, 0);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), _tokens(address(reward)));
        _assertShares(address(reward), 15, 5);
        reward.mint(_holder(), 10);
        lease.skim(TOKEN_ID, address(reward));
        _assertShares(address(reward), 20, 10);
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        _takeOpen();
        reward.mint(_holder(), 10);
        lease.skim(TOKEN_ID, address(reward));
        _assertShares(address(reward), 30, 10);
    }

    function test_creditStillSharesImmediatelyDuringWarmup() public {
        _depositPermissioned(5000);
        _takePermissioned();
        vm.prank(owner);
        lease.credit{value: 10}(TOKEN_ID, address(0), 10);
        _assertShares(address(0), 5, 5);
    }

    function test_setRewardTokensEventViewAndActivation() public {
        _depositOpen(5000);
        uint64 activeAt = uint64(vm.getBlockTimestamp() + lease.TERMS_DELAY());
        vm.expectEmit(address(lease));
        emit SeatLease.RewardTokensSet(TOKEN_ID, _tokens(address(reward)), activeAt);
        vm.prank(owner);
        lease.setRewardTokens(TOKEN_ID, _tokens(address(reward)));
        assertEq(lease.rewardTokens(TOKEN_ID), _tokens(address(reward)));
        assertEq(lease.seat(TOKEN_ID).termsActiveAt, activeAt);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.TermsNotActive.selector, TOKEN_ID, activeAt));
        lease.take(TOKEN_ID);
        _activateTerms();
        _takeOpen();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotVacant.selector, TOKEN_ID));
        lease.setRewardTokens(TOKEN_ID, new address[](0));
    }

    function test_setRewardTokensRejectsUnauthorizedMissingTooManyDuplicatesAndInvalidTokens() public {
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.setRewardTokens(TOKEN_ID, new address[](0));
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, stranger));
        lease.setRewardTokens(TOKEN_ID, new address[](0));
        vm.startPrank(owner);
        address[] memory tokens = new address[](lease.MAX_REWARD_TOKENS() + 1);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.TooManyRewardTokens.selector, tokens.length));
        lease.setRewardTokens(TOKEN_ID, tokens);
        tokens = new address[](2);
        tokens[0] = address(reward);
        tokens[1] = address(reward);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.DuplicateRewardToken.selector, address(reward)));
        lease.setRewardTokens(TOKEN_ID, tokens);
        address[5] memory invalid = [address(0), address(nft), stranger, address(lease), _holder()];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, invalid[i]));
            lease.setRewardTokens(TOKEN_ID, _tokens(invalid[i]));
        }
        lease.setRewardTokens(TOKEN_ID, _tokens(address(reward)));
        lease.setRewardTokens(TOKEN_ID, new address[](0));
        vm.stopPrank();
        assertEq(lease.rewardTokens(TOKEN_ID).length, 0);
    }

    function test_withdrawSettlesVacantRewardsAndClearsListBeforeNewOwner() public {
        _depositOpen(5000);
        _declareRewards();
        _push(10 ether);
        vm.prank(owner);
        lease.withdraw(TOKEN_ID);
        _assertShares(address(reward), 10 ether, 0);
        _assertShares(address(0), 10 ether, 0);
        assertEq(lease.rewardTokens(TOKEN_ID).length, 0);
        vm.prank(owner);
        nft.transferFrom(owner, stranger, TOKEN_ID);
        vm.startPrank(stranger);
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 0, SeatLease.Mode.Open, address(0), 0, oracle, QUESTION, "new owner");
        vm.stopPrank();
        lease.sweepFor(TOKEN_ID, address(reward), owner);
        assertEq(reward.balanceOf(owner), 10 ether);
        assertEq(lease.share(TOKEN_ID, address(reward), stranger), 0);
    }

    function test_settlementMeasuresFeeTokenReceipts() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        _depositOpen(5000);
        vm.prank(owner);
        lease.setRewardTokens(TOKEN_ID, _tokens(address(fee)));
        _activateTerms();
        _takeOpen();
        _mature();
        fee.mint(_holder(), 10000);
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        _assertShares(address(fee), 4950, 4950);
        assertEq(fee.balanceOf(address(lease)), 9900);
    }

    function test_settlementCannotReenterTermsChangeDuringTake() public {
        SettlementCallbackToken callback = new SettlementCallbackToken();
        vm.prank(owner);
        nft.transferFrom(owner, address(callback), TOKEN_ID);
        owner = address(callback);
        _depositOpen(5000);
        vm.prank(owner);
        lease.setRewardTokens(TOKEN_ID, _tokens(address(callback)));
        _activateTerms();
        callback.mint(_holder(), 10);
        callback.arm(
            lease,
            abi.encodeCall(
                SeatLease.setTerms,
                (TOKEN_ID, 10_000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, stranger, QUESTION, "swapped")
            )
        );
        _takeOpen();
        assertTrue(callback.attempted());
        assertFalse(callback.innerOk());
        assertEq(lease.seat(TOKEN_ID).ownerBps, 5000);
        assertEq(lease.seat(TOKEN_ID).oracleSigner, oracle);
        _assertShares(address(callback), 10, 0);
    }

    function test_untransferableDeclaredTokenRevertsSettlementAtomically_documented() public {
        TunableToken token = new TunableToken();
        _depositOpen(5000);
        vm.prank(owner);
        lease.setRewardTokens(TOKEN_ID, _tokens(address(token)));
        _activateTerms();
        _takeOpen();
        _mature();
        token.mint(_holder(), 10);
        vm.deal(_holder(), 10);
        token.setBehaviour(address(lease), TunableToken.Behaviour.Revert);
        vm.prank(operator);
        vm.expectRevert("blocked");
        lease.quit(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).operator, operator);
        assertEq(lease.seat(TOKEN_ID).bondHeld, BOND_AMOUNT);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0);
        assertEq(_holder().balance, 10);
        token.setBehaviour(address(lease), TunableToken.Behaviour.Normal);
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        _assertShares(address(token), 5, 5);
        _assertShares(address(0), 5, 5);
    }

    function test_sweepForPaysHeavyReceiverAfterBoundedSweepRetainsShare() public {
        HeavyRewardReceiver receiver = new HeavyRewardReceiver();
        _depositPermissioned(0);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 0, SeatLease.Mode.Permissioned, address(receiver), 0, oracle, QUESTION, "heavy");
        _activateTerms();
        vm.prank(address(receiver));
        lease.take(TOKEN_ID);
        vm.prank(stranger);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        vm.expectEmit(address(lease));
        emit SeatLease.ShareRetained(TOKEN_ID, address(0), address(receiver), 1 ether);
        lease.sweep(TOKEN_ID, address(0));
        assertEq(address(receiver).balance, 0);
        assertEq(lease.share(TOKEN_ID, address(0), address(receiver)), 1 ether);
        // A former operator must also be able to collect.
        vm.prank(owner);
        lease.cut(TOKEN_ID);
        lease.sweepFor(TOKEN_ID, address(0), address(receiver));
        assertEq(address(receiver).balance, 1 ether);
        assertEq(receiver.slots(7), 1 ether);
        assertEq(lease.share(TOKEN_ID, address(0), address(receiver)), 0);
        assertEq(lease.totalCredited(address(0)), 0);
    }

    function test_sweepForWithFullGasRemainsReentrancyGuarded() public {
        ReentrantSweeper receiver = new ReentrantSweeper(lease, TOKEN_ID);
        _depositPermissioned(0);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 0, SeatLease.Mode.Permissioned, address(receiver), 0, oracle, QUESTION, "reenter");
        _activateTerms();
        vm.prank(address(receiver));
        lease.take(TOKEN_ID);
        vm.prank(stranger);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        lease.sweepFor(TOKEN_ID, address(0), address(receiver));
        assertTrue(receiver.reentered());
        assertFalse(receiver.innerOk());
        assertEq(address(receiver).balance, 1 ether);
        assertEq(lease.totalCredited(address(0)), 0);
    }

    function test_instantQuitAndRetakeRejectsOldAttestation_documented() public {
        vm.roll(100);
        _depositOpen(5000);
        _takeOpen();
        SeatLease.OracleAttestation memory a = _goodAttestation(keccak256("quit"));
        bytes memory sig = _signAttestation(oracleKey, a);
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatVacant.selector, TOKEN_ID));
        lease.cutByOracle(TOKEN_ID, a, sig);
        vm.roll(110);
        _takeOpen();
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleWindowPredatesTenure.selector, uint64(100), uint64(110)));
        lease.cutByOracle(TOKEN_ID, a, sig);
        assertEq(lease.seat(TOKEN_ID).operator, operator);
        assertEq(lease.seat(TOKEN_ID).bondHeld, BOND_AMOUNT);
    }

    function test_plainTransferToHolderLocksSeat_documented() public {
        _depositOpen(5000);
        address holder = _holder();
        vm.startPrank(owner);
        lease.withdraw(TOKEN_ID);
        nft.transferFrom(owner, holder, TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, owner));
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.withdraw(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.NotRegistry.selector, owner));
        SeatHolder(payable(holder)).releaseNft(owner);
        vm.stopPrank();
        assertEq(nft.ownerOf(TOKEN_ID), holder);
    }
}
