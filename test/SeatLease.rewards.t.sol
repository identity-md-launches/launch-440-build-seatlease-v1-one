// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./utils/Base.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {MockDistributor} from "../src/mocks/MockDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    FeeOnTransferToken,
    TunableToken,
    ZeroMoveToken,
    EthRejecter,
    ReentrantSweeper,
    ReentrantDistributor,
    Thief,
    EthPayer,
    EvilNFT
} from "./utils/Actors.sol";

/// @dev credit / claim / sweep: booking, split math, guards and reentrancy.
contract SeatLeaseRewardsTest is Base {
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public override {
        super.setUp();
        reward.mint(owner, 10 * AMOUNT);
        reward.mint(stranger, 10 * AMOUNT);
        reward.mint(address(distributor), 10 * AMOUNT);
        vm.deal(address(distributor), 10 ether);
    }

    // ------------------------------------------------------------------ credit

    function test_credit_erc20BooksToSeat() public {
        _depositOpen(5000);
        vm.startPrank(stranger);
        reward.approve(address(lease), AMOUNT);
        vm.expectEmit(address(lease));
        emit SeatLease.Booked(TOKEN_ID, address(reward), AMOUNT);
        vm.expectEmit(address(lease));
        emit SeatLease.Credited(TOKEN_ID, address(reward), stranger, AMOUNT);
        lease.credit(TOKEN_ID, address(reward), AMOUNT);
        vm.stopPrank();
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
        assertEq(lease.totalCredited(address(reward)), AMOUNT);
        assertEq(reward.balanceOf(address(lease)), AMOUNT);
    }

    function test_credit_ethBooksToSeat() public {
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectEmit(address(lease));
        emit SeatLease.Credited(TOKEN_ID, address(0), stranger, 1 ether);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        assertEq(lease.credited(TOKEN_ID, address(0)), 1 ether);
        assertEq(lease.totalCredited(address(0)), 1 ether);
        assertEq(address(lease).balance, 1 ether);
    }

    function test_credit_revertsWhenNotDeposited() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.credit{value: 1}(TOKEN_ID, address(0), 1);
    }

    function test_credit_revertsOnZeroAmount() public {
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.credit(TOKEN_ID, address(reward), 0);
    }

    function test_credit_revertsOnEthValueMismatch() public {
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.WrongValue.selector, 2, 1));
        lease.credit{value: 1}(TOKEN_ID, address(0), 2);
    }

    function test_credit_revertsOnEthWithErc20() public {
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.WrongValue.selector, 0, 1));
        lease.credit{value: 1}(TOKEN_ID, address(reward), 1);
    }

    function test_credit_revertsWithoutAllowance() public {
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(lease), 0, AMOUNT)
        );
        lease.credit(TOKEN_ID, address(reward), AMOUNT);
    }

    function test_credit_feeOnTransferBooksReceivedAmount() public {
        _depositOpen(5000);
        FeeOnTransferToken fee = new FeeOnTransferToken();
        fee.mint(stranger, AMOUNT);
        vm.startPrank(stranger);
        fee.approve(address(lease), AMOUNT);
        lease.credit(TOKEN_ID, address(fee), AMOUNT);
        vm.stopPrank();
        uint256 expected = AMOUNT - AMOUNT / 100;
        assertEq(lease.credited(TOKEN_ID, address(fee)), expected);
        assertEq(fee.balanceOf(address(lease)), expected);
    }

    function test_credit_revertsWhenNothingArrives() public {
        _depositOpen(5000);
        ZeroMoveToken zero = new ZeroMoveToken();
        vm.prank(stranger);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.credit(TOKEN_ID, address(zero), AMOUNT);
        assertEq(lease.credited(TOKEN_ID, address(zero)), 0);
    }

    function test_credit_isReentrancyGuardedViaClaim() public {
        _depositOpen(5000);
        ReentrantDistributor re = new ReentrantDistributor();
        re.setPayload(abi.encodeCall(SeatLease.credit, (TOKEN_ID, address(reward), 1)));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SeatLease.ClaimFailed.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            )
        );
        lease.claim(TOKEN_ID, address(re), abi.encodeCall(ReentrantDistributor.claim, ()), new address[](0));
    }

    // ------------------------------------------------------------------ sweep

    function _creditBoth() internal {
        vm.startPrank(stranger);
        reward.approve(address(lease), AMOUNT);
        lease.credit(TOKEN_ID, address(reward), AMOUNT);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        vm.stopPrank();
    }

    function test_sweep_erc20SplitsAt5000() public {
        _depositOpen(5000);
        _takeOpen();
        _creditBoth();
        vm.prank(stranger);
        vm.expectEmit(address(lease));
        emit SeatLease.Swept(TOKEN_ID, address(reward), owner, AMOUNT / 2, operator, AMOUNT / 2);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 10 * AMOUNT + AMOUNT / 2);
        assertEq(reward.balanceOf(operator), AMOUNT / 2);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(lease.totalCredited(address(reward)), 0);
        assertEq(reward.balanceOf(address(lease)), 0);
    }

    function test_sweep_ethSplitsAt5000() public {
        _depositOpen(5000);
        _takeOpen();
        _creditBoth();
        uint256 ownerBefore = owner.balance;
        uint256 operatorBefore = operator.balance;
        lease.sweep(TOKEN_ID, address(0));
        assertEq(owner.balance, ownerBefore + 0.5 ether);
        assertEq(operator.balance, operatorBefore + 0.5 ether);
        assertEq(address(lease).balance, 0);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0);
    }

    function test_sweep_allToOperatorAt0() public {
        _depositOpen(0);
        _takeOpen();
        _creditBoth();
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 10 * AMOUNT);
        assertEq(reward.balanceOf(operator), AMOUNT);
    }

    function test_sweep_allToOwnerAt10000() public {
        _depositOpen(10_000);
        _takeOpen();
        _creditBoth();
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 11 * AMOUNT);
        assertEq(reward.balanceOf(operator), 0);
    }

    function test_sweep_allToOwnerWhenVacant() public {
        _depositOpen(0);
        _creditBoth();
        vm.expectEmit(address(lease));
        emit SeatLease.Swept(TOKEN_ID, address(reward), owner, AMOUNT, address(0), 0);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 11 * AMOUNT);
        uint256 before = owner.balance;
        lease.sweep(TOKEN_ID, address(0));
        assertEq(owner.balance, before + 1 ether);
    }

    function test_sweep_unsweptBalanceGoesToOwnerAfterCut() public {
        _depositOpen(0);
        _takeOpen();
        _creditBoth();
        vm.prank(owner);
        lease.cut(TOKEN_ID);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(operator), 0);
        assertEq(reward.balanceOf(owner), 11 * AMOUNT);
    }

    function test_sweep_roundsDustToOperator() public {
        _depositOpen(3333);
        _takeOpen();
        vm.startPrank(stranger);
        reward.approve(address(lease), 10);
        lease.credit(TOKEN_ID, address(reward), 10);
        vm.stopPrank();
        lease.sweep(TOKEN_ID, address(reward));
        // 10 * 3333 / 10000 = 3 to owner, 7 to operator
        assertEq(reward.balanceOf(owner), 10 * AMOUNT + 3);
        assertEq(reward.balanceOf(operator), 7);
    }

    function test_sweep_revertsWhenNothingBooked() public {
        _depositOpen(5000);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.sweep(TOKEN_ID, address(reward));
    }

    function test_sweep_revertsWhenNotDeposited() public {
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.sweep(TOKEN_ID, address(reward));
    }

    function test_sweep_revertsWhenOperatorRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();
        _deposit(5000, SeatLease.Mode.Permissioned, address(rejecter), 0, oracle);
        vm.prank(address(rejecter));
        lease.take(TOKEN_ID);
        _creditBoth();
        vm.expectRevert(abi.encodeWithSelector(SeatLease.EthTransferFailed.selector, address(rejecter), 0.5 ether));
        lease.sweep(TOKEN_ID, address(0));
        // The owner can still cut the operator and then sweep everything.
        vm.prank(owner);
        lease.cut(TOKEN_ID);
        lease.sweep(TOKEN_ID, address(0));
        assertEq(address(lease).balance, 0);
    }

    function test_sweep_revertsWhenOwnerRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();
        vm.prank(owner);
        nft.transferFrom(owner, address(rejecter), TOKEN_ID);
        vm.startPrank(address(rejecter));
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), 0, oracle, QUESTION, "");
        vm.stopPrank();
        vm.prank(stranger);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.EthTransferFailed.selector, address(rejecter), 1 ether));
        lease.sweep(TOKEN_ID, address(0));
    }

    function test_sweep_isReentrancyGuarded() public {
        _depositOpen(0);
        ReentrantSweeper sweeper = new ReentrantSweeper(lease, TOKEN_ID);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 0, SeatLease.Mode.Permissioned, address(sweeper), 0, oracle, QUESTION, "");
        vm.prank(address(sweeper));
        lease.take(TOKEN_ID);
        vm.prank(stranger);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.EthTransferFailed.selector, address(sweeper), 1 ether));
        lease.sweep(TOKEN_ID, address(0));
        assertEq(lease.credited(TOKEN_ID, address(0)), 1 ether);
    }

    function test_sweep_bondTokenAsRewardDoesNotTouchBond() public {
        _depositOpen(5000);
        _takeOpen();
        vm.startPrank(stranger);
        bond.approve(address(lease), 10);
        lease.credit(TOKEN_ID, address(bond), 10);
        vm.stopPrank();
        lease.sweep(TOKEN_ID, address(bond));
        assertEq(bond.balanceOf(address(lease)), BOND_AMOUNT);
        assertEq(lease.seat(TOKEN_ID).bondHeld, BOND_AMOUNT);
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        assertEq(bond.balanceOf(address(lease)), 0);
    }

    // ------------------------------------------------------------------ claim

    function test_claim_booksTokenIncrease() public {
        _depositOpen(5000);
        _takeOpen();
        distributor.setReward(address(lease), AMOUNT, 0);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        bytes memory data = abi.encodeCall(MockDistributor.claim, ());
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.Claimed(TOKEN_ID, address(distributor), data);
        vm.expectEmit(address(lease));
        emit SeatLease.Booked(TOKEN_ID, address(reward), AMOUNT);
        lease.claim(TOKEN_ID, address(distributor), data, tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
        assertEq(lease.totalCredited(address(reward)), AMOUNT);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(operator), AMOUNT / 2);
    }

    function test_claim_booksEthEvenWhenNotListed() public {
        _depositOpen(5000);
        distributor.setReward(address(lease), 0, 1 ether);
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.Booked(TOKEN_ID, address(0), 1 ether);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), new address[](0));
        assertEq(lease.credited(TOKEN_ID, address(0)), 1 ether);
        assertEq(address(lease).balance, 1 ether);
    }

    function test_claim_booksEthAndTokenWhenBothListed() public {
        _depositOpen(5000);
        distributor.setReward(address(lease), AMOUNT, 1 ether);
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(reward);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(TOKEN_ID, address(0)), 1 ether);
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
    }

    function test_claim_ethFromPlainPayerIsBooked() public {
        _depositOpen(5000);
        EthPayer payer = new EthPayer();
        vm.deal(address(payer), 2 ether);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(payer), abi.encodeCall(EthPayer.pay, (2 ether)), new address[](0));
        assertEq(lease.credited(TOKEN_ID, address(0)), 2 ether);
        // Outside of claim the same payer cannot push ETH in.
        vm.expectRevert("pay failed");
        payer.pay(1);
    }

    function test_mockDistributor_fundingAndFailedPayout() public {
        MockDistributor d = new MockDistributor(address(reward));
        (bool ok,) = address(d).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(d).balance, 1 ether);
        EthRejecter rejecter = new EthRejecter();
        d.setReward(address(rejecter), 0, 1 ether);
        vm.prank(address(rejecter));
        vm.expectRevert("eth payout failed");
        d.claim();
    }

    function test_claim_zeroGainBooksNothing() public {
        _depositOpen(5000);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0);
    }

    function test_claim_revertsForNonOwner() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, operator));
        lease.claim(TOKEN_ID, address(distributor), "", new address[](0));
    }

    function test_claim_revertsWhenNotDeposited() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.claim(TOKEN_ID, address(distributor), "", new address[](0));
    }

    function test_claim_forbidsNftBondSelfAndBookedTokens() public {
        _depositOpen(5000);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(nft)));
        lease.claim(TOKEN_ID, address(nft), "", new address[](0));
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(bond)));
        lease.claim(TOKEN_ID, address(bond), "", new address[](0));
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(lease)));
        lease.claim(TOKEN_ID, address(lease), "", new address[](0));
        vm.stopPrank();

        // A reward token becomes a forbidden target as soon as anything is booked in it.
        vm.startPrank(stranger);
        reward.approve(address(lease), AMOUNT);
        lease.credit(TOKEN_ID, address(reward), AMOUNT);
        vm.stopPrank();
        bytes memory drain = abi.encodeCall(IERC20.transfer, (owner, AMOUNT));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(reward)));
        lease.claim(TOKEN_ID, address(reward), drain, new address[](0));
        assertEq(reward.balanceOf(address(lease)), AMOUNT);
    }

    function test_claim_cannotDrainBookedEthByTargetingZeroAddress() public {
        _depositOpen(5000);
        vm.prank(stranger);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(0)));
        lease.claim(TOKEN_ID, address(0), "", new address[](0));
    }

    function test_claim_revertsWhenTargetReverts() public {
        _depositOpen(5000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ClaimFailed.selector, bytes("")));
        lease.claim(TOKEN_ID, address(distributor), abi.encodeWithSignature("nope()"), new address[](0));
    }

    function test_claim_revertsWhenListedBalanceDecreases() public {
        _depositOpen(5000);
        TunableToken t = new TunableToken();
        t.mint(address(lease), 5); // unbooked dust held by the registry
        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        bytes memory burn = abi.encodeCall(TunableToken.burnFrom, (address(lease), 5));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.BookedBalanceDecreased.selector, address(t), 5, 0));
        lease.claim(TOKEN_ID, address(t), burn, tokens);
    }

    function test_claim_revertsWhenNftLeaves() public {
        EvilNFT evil = new EvilNFT();
        evil.mint(owner, TOKEN_ID);
        SeatLease evilLease = new SeatLease(address(evil), address(bond), WORKER_NAME, WORKER_VERSION);
        vm.prank(owner);
        evilLease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), 0, oracle, QUESTION, "");
        Thief thief = new Thief();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NftNotHeld.selector, TOKEN_ID));
        evilLease.claim(
            TOKEN_ID, address(thief), abi.encodeCall(Thief.steal, (evil, TOKEN_ID, owner)), new address[](0)
        );
        assertEq(evil.ownerOf(TOKEN_ID), address(evilLease));
    }

    function test_claim_reentrancyIntoSweepClaimAndCutIsBlocked() public {
        _depositOpen(5000);
        _takeOpen();
        _creditBoth();
        ReentrantDistributor re = new ReentrantDistributor();
        bytes memory expected = abi.encodeWithSelector(
            SeatLease.ClaimFailed.selector,
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        bytes[] memory payloads = new bytes[](4);
        payloads[0] = abi.encodeCall(SeatLease.sweep, (TOKEN_ID, address(reward)));
        payloads[1] = abi.encodeCall(SeatLease.claim, (TOKEN_ID, address(re), "", new address[](0)));
        payloads[2] = abi.encodeCall(SeatLease.cut, (TOKEN_ID));
        payloads[3] = abi.encodeCall(SeatLease.quit, (TOKEN_ID));
        for (uint256 i; i < payloads.length; ++i) {
            re.setPayload(payloads[i]);
            vm.prank(owner);
            vm.expectRevert(expected);
            lease.claim(TOKEN_ID, address(re), abi.encodeCall(ReentrantDistributor.claim, ()), new address[](0));
        }
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
    }

    function test_claim_reentrantWithdrawIsBlocked() public {
        _depositOpen(5000);
        ReentrantDistributor re = new ReentrantDistributor();
        re.setPayload(abi.encodeCall(SeatLease.withdraw, (TOKEN_ID)));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SeatLease.ClaimFailed.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            )
        );
        lease.claim(TOKEN_ID, address(re), abi.encodeCall(ReentrantDistributor.claim, ()), new address[](0));
        assertEq(nft.ownerOf(TOKEN_ID), address(lease));
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_sweepSplit(uint16 bps, uint256 amount) public {
        bps = uint16(bound(bps, 0, 10_000));
        amount = bound(amount, 1, 10 * AMOUNT);
        _depositOpen(bps);
        _takeOpen();
        vm.startPrank(stranger);
        reward.approve(address(lease), amount);
        lease.credit(TOKEN_ID, address(reward), amount);
        vm.stopPrank();
        lease.sweep(TOKEN_ID, address(reward));
        uint256 ownerShare = (amount * bps) / 10_000;
        assertEq(reward.balanceOf(owner), 10 * AMOUNT + ownerShare);
        assertEq(reward.balanceOf(operator), amount - ownerShare);
        assertEq(reward.balanceOf(address(lease)), 0);
    }

    function testFuzz_sweepEthSplit(uint16 bps, uint96 amount) public {
        bps = uint16(bound(bps, 0, 10_000));
        vm.assume(amount > 0);
        _depositOpen(bps);
        _takeOpen();
        vm.deal(stranger, amount);
        vm.prank(stranger);
        lease.credit{value: amount}(TOKEN_ID, address(0), amount);
        uint256 ownerBefore = owner.balance;
        uint256 operatorBefore = operator.balance;
        lease.sweep(TOKEN_ID, address(0));
        uint256 ownerShare = (uint256(amount) * bps) / 10_000;
        assertEq(owner.balance, ownerBefore + ownerShare);
        assertEq(operator.balance, operatorBefore + amount - ownerShare);
    }

    function testFuzz_anyoneCanCreditAndSweep(address caller, uint256 amount) public {
        vm.assume(caller != address(0) && caller != address(lease) && caller.code.length == 0);
        // The caller may coincide with the owner or operator; measure from its starting balance rather than
        // assuming it starts empty.
        amount = bound(amount, 1, 10 * AMOUNT);
        _depositOpen(2500);
        _takeOpen();
        reward.mint(caller, amount);
        uint256 callerBefore = reward.balanceOf(caller);
        uint256 ownerBefore = reward.balanceOf(owner);
        uint256 operatorBefore = reward.balanceOf(operator);
        vm.startPrank(caller);
        reward.approve(address(lease), amount);
        lease.credit(TOKEN_ID, address(reward), amount);
        lease.sweep(TOKEN_ID, address(reward));
        vm.stopPrank();
        uint256 ownerShare = (amount * 2500) / 10_000;
        if (caller == owner) {
            assertEq(reward.balanceOf(owner), ownerBefore - amount + ownerShare);
            assertEq(reward.balanceOf(operator), operatorBefore + amount - ownerShare);
        } else if (caller == operator) {
            assertEq(reward.balanceOf(operator), operatorBefore - amount + amount - ownerShare);
            assertEq(reward.balanceOf(owner), ownerBefore + ownerShare);
        } else {
            assertEq(reward.balanceOf(caller), callerBefore - amount);
            assertEq(reward.balanceOf(owner), ownerBefore + ownerShare);
            assertEq(reward.balanceOf(operator), operatorBefore + amount - ownerShare);
        }
        assertEq(reward.balanceOf(address(lease)), 0);
    }
}
