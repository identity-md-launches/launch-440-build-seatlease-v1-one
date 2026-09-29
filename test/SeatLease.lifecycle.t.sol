// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./utils/Base.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {SeatHolder} from "../src/SeatHolder.sol";
import {MockSeatNFT} from "../src/mocks/MockSeatNFT.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    FeeOnTransferToken,
    TunableToken,
    ReentrantBondToken,
    EvilNFT,
    EthRejecter,
    PlainWallet,
    HolderDriver
} from "./utils/Actors.sol";

/// @dev deposit / setTerms / take / quit / cut / withdraw, both modes, bond return and escrow.
contract SeatLeaseLifecycleTest is Base {
    // ------------------------------------------------------------------ constructor

    function test_constructor_recordsParameters() public view {
        assertEq(address(lease.seatNFT()), address(nft));
        assertEq(address(lease.bondToken()), address(bond));
        (string memory name, string memory version, uint256 chainId, address verifying) = lease.workerDomain();
        assertEq(name, WORKER_NAME);
        assertEq(version, WORKER_VERSION);
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(nft));
        assertEq(lease.BPS(), 10_000);
        assertEq(lease.MAX_LISTING_BYTES(), 280);
        assertEq(lease.TERMS_DELAY(), 1 hours);
        assertEq(lease.holderOf(TOKEN_ID), address(0));
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(SeatLease.ZeroAddress.selector);
        new SeatLease(address(0), address(bond), WORKER_NAME, WORKER_VERSION);
        vm.expectRevert(SeatLease.ZeroAddress.selector);
        new SeatLease(address(nft), address(0), WORKER_NAME, WORKER_VERSION);
    }

    function test_receive_revertsOnPlainEth() public {
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(lease).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(ret), SeatLease.DirectEthNotAccepted.selector);
        assertEq(address(lease).balance, 0);
    }

    // ------------------------------------------------------------------ deposit

    function test_deposit_recordsOwnerTermsAndHoldsNft() public {
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        vm.expectEmit(true, false, false, false, address(lease));
        emit SeatLease.HolderCreated(TOKEN_ID, address(0));
        vm.expectEmit(address(lease));
        emit SeatLease.SeatDeposited(TOKEN_ID, owner);
        vm.expectEmit(address(lease));
        emit SeatLease.TermsSet(
            TOKEN_ID,
            5000,
            SeatLease.Mode.Open,
            address(0),
            BOND_AMOUNT,
            oracle,
            QUESTION,
            "seat 7 for lease",
            uint64(block.timestamp)
        );
        lease.deposit(
            TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "seat 7 for lease"
        );
        vm.stopPrank();

        SeatLease.Seat memory s = lease.seat(TOKEN_ID);
        assertEq(s.owner, owner);
        assertEq(s.operator, address(0));
        assertEq(s.ownerBps, 5000);
        assertEq(uint8(s.mode), uint8(SeatLease.Mode.Open));
        assertEq(s.allowedOperator, address(0));
        assertEq(s.bondAmount, BOND_AMOUNT);
        assertEq(s.bondHeld, 0);
        assertEq(s.oracleSigner, oracle);
        assertEq(s.questionHash, QUESTION);
        assertEq(s.listing, "seat 7 for lease");
        // Terms recorded at deposit are live at once.
        assertEq(s.termsActiveAt, uint64(block.timestamp));
        assertEq(s.takenAt, 0);
        assertEq(s.takenBlock, 0);

        // The seat sits in its own holder, a contract the registry created for this token id.
        address holder = _holder();
        assertTrue(holder != address(0) && holder != address(lease));
        assertGt(holder.code.length, 0);
        assertEq(nft.ownerOf(TOKEN_ID), holder);
        assertEq(address(SeatHolder(payable(holder)).registry()), address(lease));
        assertEq(address(SeatHolder(payable(holder)).seatNFT()), address(nft));
        assertEq(SeatHolder(payable(holder)).tokenId(), TOKEN_ID);
    }

    function test_deposit_holderIsDeterministicAndReused() public {
        _depositOpen(5000);
        address holder = _holder();
        bytes32 initHash = keccak256(abi.encodePacked(type(SeatHolder).creationCode, abi.encode(nft, TOKEN_ID)));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(lease), bytes32(TOKEN_ID), initHash))))
        );
        assertEq(holder, predicted);

        vm.prank(owner);
        lease.withdraw(TOKEN_ID);
        assertEq(lease.holderOf(TOKEN_ID), holder, "holder survives withdraw");
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 1, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
        vm.stopPrank();
        assertEq(lease.holderOf(TOKEN_ID), holder, "same holder on redeposit");
        assertEq(nft.ownerOf(TOKEN_ID), holder);

        // Another token id gets its own holder.
        nft.mint(owner, 8);
        vm.startPrank(owner);
        nft.approve(address(lease), 8);
        lease.deposit(8, 1, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
        vm.stopPrank();
        assertTrue(lease.holderOf(8) != holder);
        assertEq(nft.ownerOf(8), lease.holderOf(8));
    }

    function test_deposit_revertsWhenCallerDoesNotOwnNft() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, stranger));
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
    }

    function test_deposit_revertsWhenAlreadyDeposited() public {
        _depositOpen(5000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatAlreadyDeposited.selector, TOKEN_ID));
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
    }

    function test_deposit_revertsWithoutApproval() public {
        vm.prank(owner);
        vm.expectRevert();
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        assertEq(nft.ownerOf(TOKEN_ID), owner);
    }

    function test_deposit_revertsOnBadBps() public {
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.InvalidBps.selector, uint16(10_001)));
        lease.deposit(TOKEN_ID, 10_001, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        vm.stopPrank();
    }

    function test_deposit_revertsOnLongListing() public {
        string memory long = new string(281);
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ListingTooLong.selector, 281));
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, long);
        vm.stopPrank();
    }

    function test_deposit_acceptsMaxListing() public {
        string memory max = new string(280);
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, max);
        vm.stopPrank();
        assertEq(bytes(lease.seat(TOKEN_ID).listing).length, 280);
    }

    function test_onERC721Received_registryRefusesEveryNft() public {
        // The registry has no receiver hook at all: a safe transfer to it reverts inside the NFT.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(lease)));
        nft.safeTransferFrom(owner, address(lease), TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), owner);
    }

    function test_onERC721Received_holderRejectsDirectTransferOfSeatNft() public {
        _depositOpen(5000);
        vm.prank(owner);
        lease.withdraw(TOKEN_ID);
        address holder = _holder();
        // Outside of a deposit the holder refuses even its own token id.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.UnexpectedToken.selector, address(nft), TOKEN_ID));
        nft.safeTransferFrom(owner, holder, TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), owner);
        // And never another token id of the seat collection.
        nft.mint(owner, 8);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.UnexpectedToken.selector, address(nft), 8));
        nft.safeTransferFrom(owner, holder, 8);
    }

    function test_onERC721Received_holderRejectsOtherCollections() public {
        _depositOpen(5000);
        MockSeatNFT other = new MockSeatNFT();
        other.mint(owner, 1);
        address holder = _holder();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.UnexpectedToken.selector, address(other), 1));
        other.safeTransferFrom(owner, holder, 1);
    }

    function test_onERC721Received_holderRejectsDirectCall() public {
        _depositOpen(5000);
        SeatHolder holder = SeatHolder(payable(_holder()));
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.UnexpectedToken.selector, address(this), TOKEN_ID));
        holder.onERC721Received(address(this), owner, TOKEN_ID, "");
        assertFalse(lease.depositInFlight(TOKEN_ID));
    }

    function test_holder_releaseEthRevertsWhenRegistryCannotReceive() public {
        HolderDriver driver = new HolderDriver(nft, TOKEN_ID);
        SeatHolder holder = driver.holder();
        assertEq(address(holder.registry()), address(driver));
        vm.deal(address(holder), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.EthTransferFailed.selector, address(driver), 1 ether));
        driver.release(address(0), 1 ether);
        assertEq(address(holder).balance, 1 ether);
    }

    function test_holder_onlyRegistryMayDrive() public {
        _depositOpen(5000);
        SeatHolder holder = SeatHolder(payable(_holder()));
        vm.deal(address(holder), 1 ether);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.NotRegistry.selector, owner));
        holder.execute(address(nft), abi.encodeCall(nft.transferFrom, (address(holder), owner, TOKEN_ID)));
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.NotRegistry.selector, owner));
        holder.releaseNft(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.NotRegistry.selector, owner));
        holder.release(address(0), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.NotRegistry.selector, owner));
        holder.release(address(bond), 1);
        vm.stopPrank();
        assertEq(nft.ownerOf(TOKEN_ID), address(holder));
        assertEq(address(holder).balance, 1 ether);
    }

    function test_deposit_rejectsHookForDifferentTokenId() public {
        (EvilNFT evil, SeatLease evilLease) = _evilSetup();
        evil.setBehaviour(EvilNFT.Behaviour.WrongTokenIdHook);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.UnexpectedToken.selector, address(evil), TOKEN_ID + 1));
        evilLease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
    }

    function test_deposit_rejectsHookFromStrangerDuringDeposit() public {
        (EvilNFT evil, SeatLease evilLease) = _evilSetup();
        evil.setBehaviour(EvilNFT.Behaviour.HookFromStranger);
        address hookCaller = address(evil.stranger());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatHolder.UnexpectedToken.selector, hookCaller, TOKEN_ID));
        evilLease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
    }

    function test_deposit_revertsWhenNftDidNotArrive() public {
        (EvilNFT evil, SeatLease evilLease) = _evilSetup();
        evil.setBehaviour(EvilNFT.Behaviour.KeepOwnership);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NftNotReceived.selector, TOKEN_ID));
        evilLease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
    }

    function test_deposit_worksWithMinimalNft() public {
        (EvilNFT evil, SeatLease evilLease) = _evilSetup();
        vm.prank(owner);
        evilLease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        assertEq(evilLease.seat(TOKEN_ID).owner, owner);
        assertEq(evil.ownerOf(TOKEN_ID), evilLease.holderOf(TOKEN_ID));
    }

    function _evilSetup() internal returns (EvilNFT evil, SeatLease evilLease) {
        evil = new EvilNFT();
        evil.mint(owner, TOKEN_ID);
        evilLease = new SeatLease(address(evil), address(bond), WORKER_NAME, WORKER_VERSION);
    }

    // ------------------------------------------------------------------ setTerms

    function test_setTerms_updatesVacantSeat() public {
        _depositOpen(5000);
        uint64 activeAt = uint64(block.timestamp + 1 hours);
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.TermsSet(
            TOKEN_ID, 1234, SeatLease.Mode.Permissioned, operator, 1, address(0), bytes32(0), "x", activeAt
        );
        lease.setTerms(TOKEN_ID, 1234, SeatLease.Mode.Permissioned, operator, 1, address(0), bytes32(0), "x");
        SeatLease.Seat memory s = lease.seat(TOKEN_ID);
        assertEq(s.ownerBps, 1234);
        assertEq(uint8(s.mode), uint8(SeatLease.Mode.Permissioned));
        assertEq(s.allowedOperator, operator);
        assertEq(s.bondAmount, 1);
        assertEq(s.oracleSigner, address(0));
        assertEq(s.questionHash, bytes32(0));
        assertEq(s.listing, "x");
        assertEq(s.termsActiveAt, activeAt);
    }

    // ---------------------------------------------------------- terms delay (finding 3b42aa8a)

    /// @dev Regression for finding 3b42aa8a: a `take` that lands after the owner changed the terms is refused
    ///      instead of seating the operator under terms it never inspected.
    function test_take_refusedUntilChangedTermsAreActive() public {
        _depositOpen(5000);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, stranger, QUESTION, "");
        uint64 activeAt = lease.seat(TOKEN_ID).termsActiveAt;
        assertEq(activeAt, uint64(vm.getBlockTimestamp() + 1 hours));

        vm.startPrank(operator);
        bond.approve(address(lease), BOND_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.TermsNotActive.selector, TOKEN_ID, activeAt));
        lease.take(TOKEN_ID);
        vm.warp(activeAt - 1);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.TermsNotActive.selector, TOKEN_ID, activeAt));
        lease.take(TOKEN_ID);
        vm.warp(activeAt);
        lease.take(TOKEN_ID);
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).operator, operator);
        assertEq(lease.seat(TOKEN_ID).takenAt, uint64(block.timestamp));
        assertEq(lease.seat(TOKEN_ID).takenBlock, uint64(block.number));
    }

    /// @dev The exact scenario of finding 3b42aa8a: the owner front-runs the victim's `take` by swapping the oracle
    ///      signer for its own key. The victim is not seated and keeps its bond; there is nothing to forfeit.
    function test_take_frontRunWithSwappedOracleSignerDoesNotSeatTheVictim() public {
        (address ownerSigner, uint256 ownerSignerKey) = makeAddrAndKey("owner-signer");
        _depositOpen(5000);
        vm.prank(operator);
        bond.approve(address(lease), BOND_AMOUNT);
        // Front-run.
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, ownerSigner, QUESTION, "");
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(SeatLease.TermsNotActive.selector, TOKEN_ID, uint64(block.timestamp + 1 hours))
        );
        lease.take(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).operator, address(0));
        assertEq(bond.balanceOf(operator), 10 * BOND_AMOUNT);

        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatVacant.selector, TOKEN_ID));
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(ownerSignerKey, att));
        assertEq(bond.balanceOf(owner), 0);
    }

    /// @dev Withdrawing and redepositing with new terms is delayed the same way, so it cannot be used to swap terms
    ///      under a pending `take` either.
    function test_take_refusedAfterWithdrawAndRedepositUntilDelayPasses() public {
        _depositOpen(5000);
        vm.startPrank(owner);
        lease.withdraw(TOKEN_ID);
        uint64 activeAt = uint64(block.timestamp + 1 hours);
        assertEq(lease.seat(TOKEN_ID).termsActiveAt, activeAt);
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, stranger, QUESTION, "");
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).termsActiveAt, activeAt);

        vm.startPrank(operator);
        bond.approve(address(lease), BOND_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.TermsNotActive.selector, TOKEN_ID, activeAt));
        lease.take(TOKEN_ID);
        vm.warp(activeAt);
        lease.take(TOKEN_ID);
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).operator, operator);
    }

    function test_deposit_longAfterWithdrawIsActiveAtOnce() public {
        _depositOpen(5000);
        vm.prank(owner);
        lease.withdraw(TOKEN_ID);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).termsActiveAt, uint64(block.timestamp));
        _takeOpen();
        assertEq(lease.seat(TOKEN_ID).operator, operator);
    }

    function test_take_permissionedIsDelayedToo() public {
        _depositPermissioned(5000);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 1, SeatLease.Mode.Permissioned, operator, 0, oracle, QUESTION, "");
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(SeatLease.TermsNotActive.selector, TOKEN_ID, uint64(block.timestamp + 1 hours))
        );
        lease.take(TOKEN_ID);
        _activateTerms();
        _takePermissioned();
        assertEq(lease.seat(TOKEN_ID).operator, operator);
    }

    function test_setTerms_revertsForNonOwner() public {
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, stranger));
        lease.setTerms(TOKEN_ID, 1, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
    }

    function test_setTerms_revertsWhenNotDeposited() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.setTerms(TOKEN_ID, 1, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
    }

    function test_setTerms_revertsWhenOccupied() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotVacant.selector, TOKEN_ID));
        lease.setTerms(TOKEN_ID, 1, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
    }

    function test_setTerms_revertsOnBadBpsAndListing() public {
        _depositOpen(5000);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.InvalidBps.selector, uint16(20_000)));
        lease.setTerms(TOKEN_ID, 20_000, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(SeatLease.ListingTooLong.selector, 300));
        lease.setTerms(TOKEN_ID, 1, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), new string(300));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ take

    function test_take_open_pullsBondAndSetsOperator() public {
        _depositOpen(5000);
        uint256 before = bond.balanceOf(operator);
        vm.startPrank(operator);
        bond.approve(address(lease), BOND_AMOUNT);
        vm.expectEmit(address(lease));
        emit SeatLease.SeatTaken(TOKEN_ID, operator, BOND_AMOUNT);
        lease.take(TOKEN_ID);
        vm.stopPrank();
        SeatLease.Seat memory s = lease.seat(TOKEN_ID);
        assertEq(s.operator, operator);
        assertEq(s.bondHeld, BOND_AMOUNT);
        assertEq(bond.balanceOf(operator), before - BOND_AMOUNT);
        assertEq(bond.balanceOf(address(lease)), BOND_AMOUNT);
    }

    function test_take_open_anyoneMayTake() public {
        _depositOpen(5000);
        vm.startPrank(stranger);
        bond.approve(address(lease), BOND_AMOUNT);
        lease.take(TOKEN_ID);
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).operator, stranger);
    }

    function test_take_open_zeroBondPullsNothing() public {
        _deposit(5000, SeatLease.Mode.Open, address(0), 0, oracle);
        vm.prank(stranger);
        lease.take(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).operator, stranger);
        assertEq(lease.seat(TOKEN_ID).bondHeld, 0);
        assertEq(bond.balanceOf(address(lease)), 0);
    }

    function test_take_open_revertsWithoutAllowance() public {
        _depositOpen(5000);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(lease), 0, BOND_AMOUNT)
        );
        lease.take(TOKEN_ID);
    }

    function test_take_permissioned_onlyAllowedOperator() public {
        _depositPermissioned(5000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotAllowedOperator.selector, TOKEN_ID, stranger));
        lease.take(TOKEN_ID);
        vm.prank(operator);
        vm.expectEmit(address(lease));
        emit SeatLease.SeatTaken(TOKEN_ID, operator, 0);
        lease.take(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).operator, operator);
        assertEq(lease.seat(TOKEN_ID).bondHeld, 0);
        assertEq(bond.balanceOf(address(lease)), 0);
    }

    function test_take_permissioned_ignoresBondAmount() public {
        _deposit(5000, SeatLease.Mode.Permissioned, operator, BOND_AMOUNT, oracle);
        vm.prank(operator);
        lease.take(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).bondHeld, 0);
    }

    function test_take_revertsWhenNotDeposited() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.take(TOKEN_ID);
    }

    function test_take_revertsWhenOccupied() public {
        _depositOpen(5000);
        _takeOpen();
        vm.startPrank(stranger);
        bond.approve(address(lease), BOND_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotVacant.selector, TOKEN_ID));
        lease.take(TOKEN_ID);
        vm.stopPrank();
    }

    function test_take_open_feeOnTransferBondRecordsActualAmount() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        SeatLease feeLease = new SeatLease(address(nft), address(fee), WORKER_NAME, WORKER_VERSION);
        fee.mint(operator, BOND_AMOUNT);
        vm.startPrank(owner);
        nft.approve(address(feeLease), TOKEN_ID);
        feeLease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        vm.stopPrank();
        vm.startPrank(operator);
        fee.approve(address(feeLease), BOND_AMOUNT);
        feeLease.take(TOKEN_ID);
        uint256 held = feeLease.seat(TOKEN_ID).bondHeld;
        assertEq(held, BOND_AMOUNT - BOND_AMOUNT / 100);
        assertEq(fee.balanceOf(address(feeLease)), held);
        feeLease.quit(TOKEN_ID);
        vm.stopPrank();
        assertEq(fee.balanceOf(address(feeLease)), 0);
        assertEq(fee.balanceOf(operator), held - held / 100);
    }

    function test_take_isReentrancyGuarded() public {
        ReentrantBondToken re = new ReentrantBondToken();
        SeatLease reLease = new SeatLease(address(nft), address(re), WORKER_NAME, WORKER_VERSION);
        re.mint(operator, BOND_AMOUNT);
        vm.startPrank(owner);
        nft.approve(address(reLease), TOKEN_ID);
        reLease.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        vm.stopPrank();
        re.arm(reLease, TOKEN_ID);
        vm.startPrank(operator);
        re.approve(address(reLease), BOND_AMOUNT);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        reLease.take(TOKEN_ID);
        vm.stopPrank();
        assertEq(reLease.seat(TOKEN_ID).operator, address(0));
    }

    // ------------------------------------------------------------------ quit

    function test_quit_returnsBondAndClearsOperator() public {
        _depositOpen(5000);
        _takeOpen();
        uint256 before = bond.balanceOf(operator);
        vm.prank(operator);
        vm.expectEmit(address(lease));
        emit SeatLease.SeatQuit(TOKEN_ID, operator, BOND_AMOUNT);
        lease.quit(TOKEN_ID);
        SeatLease.Seat memory s = lease.seat(TOKEN_ID);
        assertEq(s.operator, address(0));
        assertEq(s.bondHeld, 0);
        assertEq(s.takenAt, 0);
        assertEq(s.takenBlock, 0);
        assertEq(s.owner, owner);
        assertEq(bond.balanceOf(operator), before + BOND_AMOUNT);
        assertEq(bond.balanceOf(address(lease)), 0);
    }

    function test_quit_permissionedReturnsNothing() public {
        _depositPermissioned(5000);
        _takePermissioned();
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).operator, address(0));
    }

    function test_quit_revertsForNonOperator() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotOperator.selector, TOKEN_ID, owner));
        lease.quit(TOKEN_ID);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotOperator.selector, TOKEN_ID, stranger));
        lease.quit(TOKEN_ID);
    }

    function test_quit_revertsWhenVacantOrUnknown() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotOperator.selector, TOKEN_ID, operator));
        lease.quit(TOKEN_ID);
        _depositOpen(5000);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotOperator.selector, TOKEN_ID, operator));
        lease.quit(TOKEN_ID);
    }

    function test_seatCanBeRetakenAfterQuit() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        vm.startPrank(stranger);
        bond.approve(address(lease), BOND_AMOUNT);
        lease.take(TOKEN_ID);
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).operator, stranger);
        assertEq(bond.balanceOf(address(lease)), BOND_AMOUNT);
    }

    // ------------------------------------------------------------------ cut

    function test_cut_returnsBondToOperator() public {
        _depositOpen(5000);
        _takeOpen();
        uint256 before = bond.balanceOf(operator);
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.SeatCut(TOKEN_ID, operator, BOND_AMOUNT);
        lease.cut(TOKEN_ID);
        assertEq(lease.seat(TOKEN_ID).operator, address(0));
        assertEq(lease.seat(TOKEN_ID).bondHeld, 0);
        assertEq(bond.balanceOf(operator), before + BOND_AMOUNT);
        assertEq(bond.balanceOf(owner), 0);
    }

    function test_cut_revertsForNonOwner() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, operator));
        lease.cut(TOKEN_ID);
    }

    function test_cut_revertsWhenVacant() public {
        _depositOpen(5000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatVacant.selector, TOKEN_ID));
        lease.cut(TOKEN_ID);
    }

    function test_cut_revertsWhenNotDeposited() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.cut(TOKEN_ID);
    }

    // ------------------------------------------------------------------ bond escrow fallback

    function _tunableSetup() internal returns (TunableToken t, SeatLease l) {
        t = new TunableToken();
        l = new SeatLease(address(nft), address(t), WORKER_NAME, WORKER_VERSION);
        t.mint(operator, BOND_AMOUNT);
        vm.startPrank(owner);
        nft.approve(address(l), TOKEN_ID);
        l.deposit(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle, QUESTION, "");
        vm.stopPrank();
        vm.startPrank(operator);
        t.approve(address(l), BOND_AMOUNT);
        l.take(TOKEN_ID);
        vm.stopPrank();
    }

    function test_cut_escrowsBondWhenTransferReverts() public {
        (TunableToken t, SeatLease l) = _tunableSetup();
        t.setBehaviour(operator, TunableToken.Behaviour.Revert);
        vm.prank(owner);
        vm.expectEmit(address(l));
        emit SeatLease.BondEscrowed(operator, BOND_AMOUNT);
        l.cut(TOKEN_ID);
        assertEq(l.seat(TOKEN_ID).operator, address(0));
        assertEq(l.bondOwed(operator), BOND_AMOUNT);
        assertEq(t.balanceOf(address(l)), BOND_AMOUNT);

        // Still blocked: redeem pushes through SafeERC20 and reverts, funds stay escrowed.
        vm.prank(operator);
        vm.expectRevert();
        l.redeemBond();

        t.setBehaviour(operator, TunableToken.Behaviour.Normal);
        vm.prank(operator);
        vm.expectEmit(address(l));
        emit SeatLease.BondRedeemed(operator, BOND_AMOUNT);
        l.redeemBond();
        assertEq(l.bondOwed(operator), 0);
        assertEq(t.balanceOf(operator), BOND_AMOUNT);
        assertEq(t.balanceOf(address(l)), 0);
    }

    function test_quit_escrowsBondWhenTransferReturnsFalse() public {
        (TunableToken t, SeatLease l) = _tunableSetup();
        t.setBehaviour(operator, TunableToken.Behaviour.ReturnFalse);
        vm.prank(operator);
        l.quit(TOKEN_ID);
        assertEq(l.bondOwed(operator), BOND_AMOUNT);
        assertEq(t.balanceOf(operator), 0);
    }

    function test_quit_escrowsBondWhenTransferReturnsShortData() public {
        (TunableToken t, SeatLease l) = _tunableSetup();
        t.setBehaviour(operator, TunableToken.Behaviour.ReturnShort);
        vm.prank(operator);
        l.quit(TOKEN_ID);
        // The token moved the funds but reported garbage; the registry conservatively escrows what it thinks it
        // still holds. That is a broken token, not a registry accounting path; see REVIEW.md.
        assertEq(l.bondOwed(operator), BOND_AMOUNT);
    }

    function test_quit_acceptsTransferReturningNothing() public {
        (TunableToken t, SeatLease l) = _tunableSetup();
        t.setBehaviour(operator, TunableToken.Behaviour.ReturnNothing);
        vm.prank(operator);
        l.quit(TOKEN_ID);
        assertEq(l.bondOwed(operator), 0);
        assertEq(t.balanceOf(operator), BOND_AMOUNT);
    }

    function test_redeemBond_revertsWhenNothingOwed() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NothingOwed.selector, operator));
        lease.redeemBond();
    }

    // ------------------------------------------------------------------ withdraw

    function test_withdraw_returnsNftAndClearsSeat() public {
        _depositOpen(5000);
        vm.prank(owner);
        vm.expectEmit(address(lease));
        emit SeatLease.SeatWithdrawn(TOKEN_ID, owner);
        lease.withdraw(TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), owner);
        SeatLease.Seat memory s = lease.seat(TOKEN_ID);
        assertEq(s.owner, address(0));
        assertEq(s.ownerBps, 0);
        assertEq(s.oracleSigner, address(0));
        assertEq(bytes(s.listing).length, 0);
        assertEq(s.termsActiveAt, uint64(block.timestamp + 1 hours));
    }

    /// @dev Regression for finding ef91abbe: a contract owner without `onERC721Received` can withdraw its seat,
    ///      because the holder returns it with a plain `transferFrom`.
    function test_withdraw_worksForContractOwnerWithoutReceiverHook() public {
        PlainWallet wallet = new PlainWallet();
        nft.mint(address(wallet), 8);
        wallet.exec(address(nft), abi.encodeCall(nft.approve, (address(lease), 8)));
        wallet.exec(
            address(lease),
            abi.encodeCall(
                lease.deposit, (8, 5000, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "plain")
            )
        );
        assertEq(nft.ownerOf(8), lease.holderOf(8));
        // The wallet could never receive a safe transfer.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(wallet)));
        nft.safeTransferFrom(owner, address(wallet), TOKEN_ID);

        wallet.exec(address(lease), abi.encodeCall(lease.withdraw, (8)));
        assertEq(nft.ownerOf(8), address(wallet));
        assertEq(lease.seat(8).owner, address(0));
    }

    function test_withdraw_afterQuitAndCut() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(owner);
        lease.cut(TOKEN_ID);
        vm.prank(owner);
        lease.withdraw(TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), owner);
    }

    function test_withdraw_revertsWhenOccupied() public {
        _depositOpen(5000);
        _takeOpen();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotVacant.selector, TOKEN_ID));
        lease.withdraw(TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), _holder());
    }

    function test_withdraw_revertsForNonOwner() public {
        _depositOpen(5000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, stranger));
        lease.withdraw(TOKEN_ID);
    }

    function test_withdraw_revertsWhenNotDeposited() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, TOKEN_ID));
        lease.withdraw(TOKEN_ID);
    }

    function test_redeposit_afterWithdrawStartsClean() public {
        _depositOpen(5000);
        vm.prank(owner);
        lease.withdraw(TOKEN_ID);
        vm.prank(owner);
        nft.transferFrom(owner, stranger, TOKEN_ID);
        vm.startPrank(stranger);
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, 1, SeatLease.Mode.Permissioned, operator, 0, address(0), bytes32(0), "new");
        vm.stopPrank();
        assertEq(lease.seat(TOKEN_ID).owner, stranger);
        assertEq(lease.seat(TOKEN_ID).ownerBps, 1);
        assertEq(nft.ownerOf(TOKEN_ID), _holder());
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_onlyOwnerCanAdminister(address caller) public {
        vm.assume(caller != owner);
        _depositOpen(5000);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, caller));
        lease.setTerms(TOKEN_ID, 1, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, caller));
        lease.withdraw(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, caller));
        lease.cut(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotSeatOwner.selector, TOKEN_ID, caller));
        lease.claim(TOKEN_ID, address(distributor), "", new address[](0));
        vm.stopPrank();
    }

    function testFuzz_onlyOperatorCanQuit(address caller) public {
        vm.assume(caller != operator);
        _depositOpen(5000);
        _takeOpen();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NotOperator.selector, TOKEN_ID, caller));
        lease.quit(TOKEN_ID);
    }

    function testFuzz_bondRoundTrip(uint256 amount) public {
        amount = bound(amount, 0, 10 * BOND_AMOUNT);
        _deposit(5000, SeatLease.Mode.Open, address(0), amount, oracle);
        uint256 before = bond.balanceOf(operator);
        vm.startPrank(operator);
        bond.approve(address(lease), amount);
        lease.take(TOKEN_ID);
        assertEq(bond.balanceOf(operator), before - amount);
        assertEq(lease.seat(TOKEN_ID).bondHeld, amount);
        lease.quit(TOKEN_ID);
        vm.stopPrank();
        assertEq(bond.balanceOf(operator), before);
        assertEq(bond.balanceOf(address(lease)), 0);
    }

    function testFuzz_termsValidation(uint16 bps, uint16 listingLen) public {
        listingLen = uint16(bound(listingLen, 0, 400));
        string memory listing = new string(listingLen);
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        if (bps > 10_000) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.InvalidBps.selector, bps));
        } else if (listingLen > 280) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.ListingTooLong.selector, listingLen));
        }
        lease.deposit(TOKEN_ID, bps, SeatLease.Mode.Open, address(0), 0, address(0), bytes32(0), listing);
        vm.stopPrank();
    }
}
