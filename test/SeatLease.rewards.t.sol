// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./utils/Base.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {SeatHolder} from "../src/SeatHolder.sol";
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
    EvilNFT,
    Burner,
    BalanceOfAnswerer,
    ClaimForDistributor,
    ClaimToDistributor,
    GasBurner
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
        ReentrantDistributor re = new ReentrantDistributor(address(lease));
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

    /// @dev Regression for finding bf40f4fd (b): what was booked during an operator's tenure stays that operator's
    ///      after the owner cuts it. `sweep` pays the owner only its own part; the operator collects with `sweepFor`.
    function test_sweep_sharesBookedDuringTenureStayWithCutOperator() public {
        _depositOpen(0);
        _takeOpen();
        _creditBoth();
        assertEq(lease.share(TOKEN_ID, address(reward), operator), AMOUNT);
        assertEq(lease.share(TOKEN_ID, address(reward), owner), 0);
        vm.prank(owner);
        lease.cut(TOKEN_ID);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 10 * AMOUNT);

        vm.expectEmit(address(lease));
        emit SeatLease.SharePaid(TOKEN_ID, address(reward), operator, AMOUNT);
        lease.sweepFor(TOKEN_ID, address(reward), operator);
        assertEq(reward.balanceOf(operator), AMOUNT);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        uint256 before = operator.balance;
        lease.sweepFor(TOKEN_ID, address(0), operator);
        assertEq(operator.balance, before + 1 ether);
        assertEq(lease.totalCredited(address(0)), 0);
    }

    /// @dev Regression for finding bf40f4fd (a): balances booked while the seat was vacant belong to the owner in
    ///      full; a stranger that takes the seat afterwards and sweeps receives none of them.
    function test_sweep_takerGetsNothingBookedBeforeItsTenure() public {
        _depositOpen(5000);
        _creditBoth();
        assertEq(lease.share(TOKEN_ID, address(reward), owner), AMOUNT);
        vm.startPrank(stranger);
        bond.approve(address(lease), BOND_AMOUNT);
        lease.take(TOKEN_ID);
        vm.expectEmit(address(lease));
        emit SeatLease.Swept(TOKEN_ID, address(reward), owner, AMOUNT, stranger, 0);
        lease.sweep(TOKEN_ID, address(reward));
        lease.sweep(TOKEN_ID, address(0));
        lease.quit(TOKEN_ID);
        vm.stopPrank();
        assertEq(reward.balanceOf(stranger), 9 * AMOUNT, "stranger only spent its credit");
        assertEq(reward.balanceOf(owner), 11 * AMOUNT);
        assertEq(bond.balanceOf(stranger), 10 * BOND_AMOUNT);
    }

    /// @dev Shares are attributed by who is seated when they are booked, tenure by tenure.
    function test_sweep_attributesEachBookingToTheTenureItHappenedIn() public {
        _depositOpen(5000);
        _creditBoth(); // vacant: all to owner
        _takeOpen();
        _creditBoth(); // operator: 50/50
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        vm.startPrank(stranger);
        bond.approve(address(lease), BOND_AMOUNT);
        lease.take(TOKEN_ID);
        vm.stopPrank();
        _creditBoth(); // stranger: 50/50

        assertEq(lease.credited(TOKEN_ID, address(reward)), 3 * AMOUNT);
        assertEq(lease.share(TOKEN_ID, address(reward), owner), 2 * AMOUNT);
        assertEq(lease.share(TOKEN_ID, address(reward), operator), AMOUNT / 2);
        assertEq(lease.share(TOKEN_ID, address(reward), stranger), AMOUNT / 2);

        vm.expectEmit(address(lease));
        emit SeatLease.Swept(TOKEN_ID, address(reward), owner, 2 * AMOUNT, stranger, AMOUNT / 2);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 12 * AMOUNT);
        assertEq(reward.balanceOf(stranger), 10 * AMOUNT - 3 * AMOUNT + AMOUNT / 2);
        assertEq(reward.balanceOf(operator), 0);
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT / 2, "former operator's share still booked");
        lease.sweepFor(TOKEN_ID, address(reward), operator);
        assertEq(reward.balanceOf(operator), AMOUNT / 2);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(lease.totalCredited(address(reward)), 0);
    }

    function test_sweep_ownerOperatingOwnSeatIsPaidOnce() public {
        _deposit(5000, SeatLease.Mode.Permissioned, owner, 0, oracle);
        vm.prank(owner);
        lease.take(TOKEN_ID);
        _creditBoth();
        assertEq(lease.share(TOKEN_ID, address(reward), owner), AMOUNT);
        vm.expectEmit(address(lease));
        emit SeatLease.Swept(TOKEN_ID, address(reward), owner, AMOUNT, owner, 0);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 11 * AMOUNT);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
    }

    function test_sweepFor_paysFormerOwnerAfterWithdrawAndNotTheNextDepositor() public {
        _depositOpen(5000);
        _creditBoth();
        vm.prank(owner);
        lease.withdraw(TOKEN_ID);
        vm.prank(owner);
        nft.transferFrom(owner, stranger, TOKEN_ID);
        vm.startPrank(stranger);
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
        vm.stopPrank();
        // The new owner has no share; the seat's booked balance is the former owner's.
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
        lease.sweepFor(TOKEN_ID, address(reward), owner);
        assertEq(reward.balanceOf(owner), 11 * AMOUNT);
        // Even a seat that is not deposited at all pays out its shares.
        vm.prank(stranger);
        lease.withdraw(TOKEN_ID);
        uint256 before = owner.balance;
        lease.sweepFor(TOKEN_ID, address(0), owner);
        assertEq(owner.balance, before + 1 ether);
    }

    function test_sweepFor_revertsWhenNothingBookedToAccount() public {
        _depositOpen(5000);
        _creditBoth();
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.sweepFor(TOKEN_ID, address(reward), stranger);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.sweepFor(99, address(reward), owner);
    }

    function test_book_emitsSharesAtBookingTime() public {
        _depositOpen(2500);
        _takeOpen();
        vm.startPrank(stranger);
        reward.approve(address(lease), AMOUNT);
        vm.expectEmit(address(lease));
        emit SeatLease.Booked(TOKEN_ID, address(reward), AMOUNT);
        vm.expectEmit(address(lease));
        emit SeatLease.ShareAccrued(TOKEN_ID, address(reward), owner, AMOUNT / 4);
        vm.expectEmit(address(lease));
        emit SeatLease.ShareAccrued(TOKEN_ID, address(reward), operator, (3 * AMOUNT) / 4);
        lease.credit(TOKEN_ID, address(reward), AMOUNT);
        vm.stopPrank();
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

    /// @dev Regression for finding 9546c25c: a recipient that rejects ETH keeps its own share booked and does not
    ///      block the other party's payout.
    function test_sweep_retainsShareWhenOperatorRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();
        _deposit(5000, SeatLease.Mode.Permissioned, address(rejecter), 0, oracle);
        vm.prank(address(rejecter));
        lease.take(TOKEN_ID);
        _creditBoth();
        uint256 ownerBefore = owner.balance;
        vm.expectEmit(address(lease));
        emit SeatLease.SharePaid(TOKEN_ID, address(0), owner, 0.5 ether);
        vm.expectEmit(address(lease));
        emit SeatLease.ShareRetained(TOKEN_ID, address(0), address(rejecter), 0.5 ether);
        lease.sweep(TOKEN_ID, address(0));
        assertEq(owner.balance, ownerBefore + 0.5 ether);
        assertEq(lease.share(TOKEN_ID, address(0), address(rejecter)), 0.5 ether);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0.5 ether);
        assertEq(lease.totalCredited(address(0)), 0.5 ether);
        assertEq(address(lease).balance, 0.5 ether);
        // Cutting the operator does not hand its share to the owner.
        vm.prank(owner);
        lease.cut(TOKEN_ID);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.sweep(TOKEN_ID, address(0));
        lease.sweepFor(TOKEN_ID, address(0), address(rejecter));
        assertEq(lease.share(TOKEN_ID, address(0), address(rejecter)), 0.5 ether, "still retained");
    }

    function test_sweep_retainsShareWhenOwnerRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();
        vm.prank(owner);
        nft.transferFrom(owner, address(rejecter), TOKEN_ID);
        vm.startPrank(address(rejecter));
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Permissioned, operator, 0, oracle, QUESTION, "");
        vm.stopPrank();
        _takePermissioned();
        vm.prank(stranger);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        uint256 before = operator.balance;
        lease.sweep(TOKEN_ID, address(0));
        assertEq(operator.balance, before + 0.5 ether, "operator paid despite owner rejecting");
        assertEq(lease.share(TOKEN_ID, address(0), address(rejecter)), 0.5 ether);
        assertEq(address(lease).balance, 0.5 ether);
    }

    function test_sweep_retainsShareWhenRecipientBurnsAllGas() public {
        GasBurner burner = new GasBurner();
        _deposit(5000, SeatLease.Mode.Permissioned, address(burner), 0, oracle);
        vm.prank(address(burner));
        lease.take(TOKEN_ID);
        _creditBoth();
        uint256 ownerBefore = owner.balance;
        uint256 gasBefore = gasleft();
        lease.sweep(TOKEN_ID, address(0));
        assertLt(gasBefore - gasleft(), 400_000, "push is gas-bounded");
        assertEq(owner.balance, ownerBefore + 0.5 ether);
        assertEq(lease.share(TOKEN_ID, address(0), address(burner)), 0.5 ether);
    }

    function test_sweep_retainsShareWhenTokenRefusesRecipient() public {
        TunableToken t = new TunableToken();
        t.mint(stranger, AMOUNT);
        _depositOpen(5000);
        _takeOpen();
        vm.startPrank(stranger);
        t.approve(address(lease), AMOUNT);
        lease.credit(TOKEN_ID, address(t), AMOUNT);
        vm.stopPrank();
        t.setBehaviour(operator, TunableToken.Behaviour.Revert);
        lease.sweep(TOKEN_ID, address(t));
        assertEq(t.balanceOf(owner), AMOUNT / 2);
        assertEq(t.balanceOf(operator), 0);
        assertEq(lease.share(TOKEN_ID, address(t), operator), AMOUNT / 2);
        t.setBehaviour(operator, TunableToken.Behaviour.ReturnFalse);
        lease.sweepFor(TOKEN_ID, address(t), operator);
        assertEq(lease.share(TOKEN_ID, address(t), operator), AMOUNT / 2);
        t.setBehaviour(operator, TunableToken.Behaviour.Normal);
        lease.sweepFor(TOKEN_ID, address(t), operator);
        assertEq(t.balanceOf(operator), AMOUNT / 2);
        assertEq(lease.credited(TOKEN_ID, address(t)), 0);
    }

    function test_sweep_isReentrancyGuarded() public {
        _depositOpen(0);
        ReentrantSweeper sweeper = new ReentrantSweeper(lease, TOKEN_ID);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 0, SeatLease.Mode.Permissioned, address(sweeper), 0, oracle, QUESTION, "");
        _activateTerms();
        vm.prank(address(sweeper));
        lease.take(TOKEN_ID);
        vm.prank(stranger);
        lease.credit{value: 1 ether}(TOKEN_ID, address(0), 1 ether);
        // The reentrant inner sweep is refused; the outer one completes and pays exactly once.
        lease.sweep(TOKEN_ID, address(0));
        assertTrue(sweeper.reentered());
        assertFalse(sweeper.innerOk());
        assertEq(address(sweeper).balance, 1 ether);
        assertEq(lease.credited(TOKEN_ID, address(0)), 0);
        assertEq(address(lease).balance, 0);
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
        // Holder rewards begin sharing after the tenure warm-up.
        _activateTerms();
        distributor.setReward(_holder(), AMOUNT, 0);
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
        distributor.setReward(_holder(), 0, 1 ether);
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.Booked(TOKEN_ID, address(0), 1 ether);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), new address[](0));
        assertEq(lease.credited(TOKEN_ID, address(0)), 1 ether);
        assertEq(address(lease).balance, 1 ether);
    }

    function test_claim_booksEthAndTokenWhenBothListed() public {
        _depositOpen(5000);
        distributor.setReward(_holder(), AMOUNT, 1 ether);
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
        address holder = _holder();
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, holder));
        lease.claim(TOKEN_ID, holder, "", new address[](0));
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
        t.mint(_holder(), 5); // not yet booked, held by the seat's wallet
        Burner burner = new Burner();
        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        bytes memory burn = abi.encodeCall(Burner.burn, (t, 5));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.HolderBalanceDecreased.selector, address(t), 5, 0));
        lease.claim(TOKEN_ID, address(burner), burn, tokens);
    }

    // ---------------------------------------------------------- per-seat wallets (finding abc1a9f1)

    /// @dev Regression for finding abc1a9f1: every seat has its own wallet, so a distributor that pays the holder
    ///      pays each seat separately and `claim` can only ever book what that seat's wallet received.
    function test_claim_booksOnlyTheCallersSeatPayout() public {
        _depositOpen(5000);
        _depositSecondSeat();
        address holder7 = _holder();
        address holder8 = lease.holderOf(8);
        assertTrue(holder7 != holder8);
        distributor.setReward(holder7, AMOUNT, 0);
        distributor.setReward(holder8, 3 * AMOUNT, 0);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        bytes memory data = abi.encodeCall(MockDistributor.claim, ());

        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), data, tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
        assertEq(lease.credited(8, address(reward)), 0);
        assertEq(distributor.reward(holder8), 3 * AMOUNT, "seat 8's payout is untouched");

        vm.prank(stranger);
        lease.claim(8, address(distributor), data, tokens);
        assertEq(lease.credited(8, address(reward)), 3 * AMOUNT);
        assertEq(reward.balanceOf(address(lease)), 4 * AMOUNT);
    }

    /// @dev The scenario of the reviewer's proof: a payout keyed to the registry address is nobody's seat and is
    ///      never booked to the caller.
    function test_claim_payoutKeyedToRegistryIsNotBookedToAnySeat() public {
        _depositOpen(5000);
        _depositSecondSeat();
        distributor.setReward(address(lease), AMOUNT, 0);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(lease.credited(8, address(reward)), 0);
        assertEq(reward.balanceOf(address(lease)), 0);
    }

    function test_claim_isMadeByTheHolderNotTheRegistry() public {
        _depositOpen(5000);
        address holder = _holder();
        distributor.setReward(address(lease), AMOUNT, 1 ether);
        distributor.setReward(holder, 2 * AMOUNT, 2 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        vm.prank(owner);
        vm.expectEmit(address(distributor));
        emit MockDistributor.Paid(holder, 2 * AMOUNT, 2 ether);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 2 * AMOUNT);
        assertEq(lease.credited(TOKEN_ID, address(0)), 2 ether);
        assertEq(holder.balance, 0, "holder is emptied into the registry");
        assertEq(reward.balanceOf(holder), 0);
    }

    // ---------------------------------------------------------- skim (finding 66e74860)

    /// @dev Regression for finding 66e74860 (a): a distributor keyed by account and claimed by a third party pays the
    ///      seat's wallet directly; `skim` books it.
    function test_skim_booksPushedRewardsFromThirdPartyClaim() public {
        _depositOpen(5000);
        _takeOpen();
        // Holder rewards begin sharing after the tenure warm-up.
        _activateTerms();
        ClaimForDistributor d = new ClaimForDistributor(reward);
        reward.mint(address(d), AMOUNT);
        vm.deal(address(d), 1 ether);
        vm.prank(stranger);
        d.claimFor(_holder(), AMOUNT, 1 ether);
        assertEq(reward.balanceOf(_holder()), AMOUNT);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);

        vm.prank(stranger);
        vm.expectEmit(address(lease));
        emit SeatLease.Booked(TOKEN_ID, address(reward), AMOUNT);
        vm.expectEmit(address(lease));
        emit SeatLease.Skimmed(TOKEN_ID, address(reward), AMOUNT);
        lease.skim(TOKEN_ID, address(reward));
        lease.skim(TOKEN_ID, address(0));
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
        assertEq(lease.credited(TOKEN_ID, address(0)), 1 ether);
        assertEq(lease.share(TOKEN_ID, address(reward), operator), AMOUNT / 2, "split by the seat's current terms");
        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(operator), AMOUNT / 2);
    }

    /// @dev Finding 66e74860 (b): a token the owner forgot to list in `claim` is booked by a later `skim`.
    function test_skim_booksTokenNotListedInClaim() public {
        _depositOpen(5000);
        distributor.setReward(_holder(), AMOUNT, 0);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), new address[](0));
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        assertEq(reward.balanceOf(_holder()), AMOUNT);
        lease.skim(TOKEN_ID, address(reward));
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
    }

    /// @dev Finding 66e74860 (c): ETH forced into the seat's wallet is attributable through `skim`.
    function test_skim_booksEthSentToHolder() public {
        _depositOpen(5000);
        vm.prank(stranger);
        (bool ok,) = _holder().call{value: 3 ether}("");
        assertTrue(ok);
        lease.skim(TOKEN_ID, address(0));
        assertEq(lease.credited(TOKEN_ID, address(0)), 3 ether);
        assertEq(address(lease).balance, 3 ether);
        assertEq(_holder().balance, 0);
    }

    function test_skim_booksReceivedAmountOfFeeOnTransferToken() public {
        _depositOpen(5000);
        FeeOnTransferToken fee = new FeeOnTransferToken();
        fee.mint(_holder(), AMOUNT);
        lease.skim(TOKEN_ID, address(fee));
        assertEq(lease.credited(TOKEN_ID, address(fee)), AMOUNT - AMOUNT / 100);
    }

    function test_skim_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.skim(TOKEN_ID, address(reward));
        _depositOpen(5000);
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.skim(TOKEN_ID, address(reward));
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.skim(TOKEN_ID, address(0));
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, address(nft)));
        lease.skim(TOKEN_ID, address(nft));
        ZeroMoveToken zero = new ZeroMoveToken();
        vm.expectRevert(SeatLease.ZeroAmount.selector);
        lease.skim(TOKEN_ID, address(zero));
    }

    function test_skim_isReentrancyGuardedViaClaim() public {
        _depositOpen(5000);
        ReentrantDistributor re = new ReentrantDistributor(address(lease));
        re.setPayload(abi.encodeCall(SeatLease.skim, (TOKEN_ID, address(0))));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SeatLease.ClaimFailed.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            )
        );
        lease.claim(TOKEN_ID, address(re), abi.encodeCall(ReentrantDistributor.claim, ()), new address[](0));
    }

    /// @dev Documented trust assumption (finding cc87fedc): the owner chooses the calldata, so at a distributor with a
    ///      recipient parameter the owner can route the payout past the seat's wallet. Nothing is booked, which is the
    ///      limit of what the registry can see; the README states that operators are protected only for rewards
    ///      that reach the seat's wallet.
    function test_claim_ownerCanRouteRecipientParameterisedPayoutsAway_documented() public {
        _depositOpen(0);
        _takeOpen();
        // Holder rewards begin sharing after the tenure warm-up.
        _activateTerms();
        ClaimToDistributor d = new ClaimToDistributor(reward);
        reward.mint(address(d), AMOUNT);
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(d), abi.encodeCall(ClaimToDistributor.claimTo, (owner, AMOUNT)), tokens);
        assertEq(reward.balanceOf(owner), 11 * AMOUNT);
        assertEq(lease.credited(TOKEN_ID, address(reward)), 0);
        // Routed to the seat's wallet instead, the whole amount is booked and, at 0 bps, owed to the operator.
        reward.mint(address(d), AMOUNT);
        address holder = _holder();
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(d), abi.encodeCall(ClaimToDistributor.claimTo, (holder, AMOUNT)), tokens);
        assertEq(lease.share(TOKEN_ID, address(reward), operator), AMOUNT);
    }

    // ---------------------------------------------------------- claim: revision regressions

    /// @dev Regression for finding 6488b67c: a token listed more than once is booked once, so a duplicate list
    ///      cannot book more than arrived and drain rewards booked to another seat.
    function test_claim_duplicateTokenEntriesBookOnce() public {
        _depositOpen(5000);
        _depositSecondSeat();
        _creditSecondSeat();
        distributor.setReward(_holder(), AMOUNT, 0);
        address[] memory tokens = new address[](11);
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i] = address(reward);
        }
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.Booked(TOKEN_ID, address(reward), AMOUNT);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
        assertEq(lease.totalCredited(address(reward)), 2 * AMOUNT);
        assertGe(reward.balanceOf(address(lease)), lease.totalCredited(address(reward)));

        lease.sweep(TOKEN_ID, address(reward));
        assertEq(reward.balanceOf(owner), 11 * AMOUNT);
        lease.sweep(8, address(reward));
        assertEq(reward.balanceOf(stranger), 10 * AMOUNT);
    }

    function test_claim_duplicateEthAndTokenEntriesBookOnce() public {
        _depositOpen(5000);
        distributor.setReward(_holder(), AMOUNT, 1 ether);
        address[] memory tokens = new address[](4);
        tokens[0] = address(0);
        tokens[1] = address(reward);
        tokens[2] = address(0);
        tokens[3] = address(reward);
        vm.prank(owner);
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        assertEq(lease.credited(TOKEN_ID, address(0)), 1 ether);
        assertEq(lease.credited(TOKEN_ID, address(reward)), AMOUNT);
    }

    /// @dev Regression for finding e2a5a011: a token is never a valid target, even while nothing is booked in it,
    ///      so the registry can never `approve` a spender that drains later credits.
    function test_claim_forbidsTokenTargetEvenWhenNothingBooked() public {
        _depositOpen(5000);
        _depositSecondSeat();
        assertEq(lease.totalCredited(address(reward)), 0);
        bytes memory approve = abi.encodeCall(IERC20.approve, (owner, type(uint256).max));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(reward)));
        lease.claim(TOKEN_ID, address(reward), approve, new address[](0));
        assertEq(reward.allowance(address(lease), owner), 0);
        assertEq(reward.allowance(_holder(), owner), 0);

        // The other seat's later credit is fully backed and sweepable.
        _creditSecondSeat();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, owner, 0, AMOUNT));
        reward.transferFrom(address(lease), owner, AMOUNT);
        lease.sweep(8, address(reward));
        assertEq(reward.balanceOf(stranger), 10 * AMOUNT);

        // Any other token-shaped contract is refused too, whether or not the registry holds any of it.
        TunableToken t = new TunableToken();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(t)));
        lease.claim(TOKEN_ID, address(t), approve, new address[](0));
        BalanceOfAnswerer answerer = new BalanceOfAnswerer();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, address(answerer)));
        lease.claim(TOKEN_ID, address(answerer), abi.encodeCall(BalanceOfAnswerer.claim, ()), new address[](0));
    }

    function test_claim_forbidsTargetWithoutCode() public {
        _depositOpen(5000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenTarget.selector, stranger));
        lease.claim(TOKEN_ID, stranger, "", new address[](0));
    }

    function test_claim_rejectsSeatNftInTokenList() public {
        _depositOpen(5000);
        address[] memory tokens = new address[](2);
        tokens[0] = address(reward);
        tokens[1] = address(nft);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, address(nft)));
        lease.claim(TOKEN_ID, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
    }

    /// @dev Regression for finding 0523d79f: the seat NFT shares the ERC-20 `transferFrom` selector, so it is
    ///      refused as a `credit` token instead of being pulled in and stuck forever.
    function test_credit_rejectsSeatNftAsToken() public {
        _depositOpen(5000);
        nft.mint(stranger, 8);
        vm.startPrank(stranger);
        nft.approve(address(lease), 8);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ForbiddenToken.selector, address(nft)));
        lease.credit(TOKEN_ID, address(nft), 8);
        vm.stopPrank();
        assertEq(nft.ownerOf(8), stranger);
        assertEq(lease.credited(TOKEN_ID, address(nft)), 0);
    }

    /// @dev Deposits seat 8 for `stranger`, so a second seat can be the victim of an accounting attack.
    function _depositSecondSeat() internal {
        nft.mint(stranger, 8);
        vm.startPrank(stranger);
        nft.approve(address(lease), 8);
        lease.deposit(8, 10_000, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
        vm.stopPrank();
    }

    /// @dev `stranger` books AMOUNT of the reward token to seat 8.
    function _creditSecondSeat() internal {
        vm.startPrank(stranger);
        reward.approve(address(lease), AMOUNT);
        lease.credit(8, address(reward), AMOUNT);
        vm.stopPrank();
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
        assertEq(evil.ownerOf(TOKEN_ID), evilLease.holderOf(TOKEN_ID));
    }

    function test_claim_reentrancyIntoSweepClaimAndCutIsBlocked() public {
        _depositOpen(5000);
        _takeOpen();
        _creditBoth();
        ReentrantDistributor re = new ReentrantDistributor(address(lease));
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
        ReentrantDistributor re = new ReentrantDistributor(address(lease));
        re.setPayload(abi.encodeCall(SeatLease.withdraw, (TOKEN_ID)));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SeatLease.ClaimFailed.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            )
        );
        lease.claim(TOKEN_ID, address(re), abi.encodeCall(ReentrantDistributor.claim, ()), new address[](0));
        assertEq(nft.ownerOf(TOKEN_ID), _holder());
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
        amount = bound(amount, 1, 10 * AMOUNT);
        _depositOpen(2500);
        _takeOpen();
        reward.mint(caller, amount);
        vm.startPrank(caller);
        reward.approve(address(lease), amount);
        lease.credit(TOKEN_ID, address(reward), amount);
        lease.sweep(TOKEN_ID, address(reward));
        vm.stopPrank();
        assertEq(reward.balanceOf(caller), 0);
        assertEq(reward.balanceOf(owner) + reward.balanceOf(operator), 10 * AMOUNT + amount);
    }
}
