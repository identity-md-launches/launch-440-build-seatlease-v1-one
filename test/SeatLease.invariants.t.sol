// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {MockSeatNFT} from "../src/mocks/MockSeatNFT.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockDistributor} from "../src/mocks/MockDistributor.sol";

/// @dev Drives the registry with a handful of actors and records ghost totals for the invariants.
contract Handler is Test {
    SeatLease public lease;
    MockSeatNFT public nft;
    MockERC20 public bond;
    MockERC20 public reward;
    MockDistributor public distributor;

    address[] public actors;
    uint256[] public tokenIds;

    uint256 public ghostCredited;
    uint256 public ghostSwept;
    uint256 public ghostEthCredited;
    uint256 public ghostEthSwept;
    uint256 public ghostBondIn;
    uint256 public ghostBondOut;
    uint256 public withdrawCalls;
    uint256 public depositCalls;
    uint256 public sweepCalls;
    uint256 public cutCalls;

    mapping(uint256 => address) public lastKnownHolder;

    constructor(SeatLease lease_, MockSeatNFT nft_, MockERC20 bond_, MockERC20 reward_, MockDistributor d) {
        lease = lease_;
        nft = nft_;
        bond = bond_;
        reward = reward_;
        distributor = d;
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            vm.deal(a, 1_000 ether);
            bond.mint(a, 1_000_000e18);
            reward.mint(a, 1_000_000e18);
        }
        for (uint256 t = 1; t <= 3; ++t) {
            tokenIds.push(t);
            nft.mint(actors[t % actors.length], t);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (uint256) {
        return tokenIds[seed % tokenIds.length];
    }

    function deposit(uint256 actorSeed, uint256 tokenSeed, uint16 bps, bool open, uint256 bondAmount) external {
        address a = _actor(actorSeed);
        uint256 t = _token(tokenSeed);
        bps = uint16(bound(bps, 0, 10_000));
        bondAmount = bound(bondAmount, 0, 1_000e18);
        if (nft.ownerOf(t) != a) return;
        vm.startPrank(a);
        nft.approve(address(lease), t);
        lease.deposit(
            t,
            bps,
            open ? SeatLease.Mode.Open : SeatLease.Mode.Permissioned,
            actors[(actorSeed % actors.length + 1) % actors.length],
            bondAmount,
            address(0),
            bytes32(0),
            "inv"
        );
        vm.stopPrank();
        depositCalls++;
    }

    /// @dev Lets the terms-activation delay that follows `setTerms` and `withdraw` elapse.
    function passTime(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 2 hours));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function setTerms(uint256 tokenSeed, uint16 bps, bool open, uint256 bondAmount) external {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0) || s.operator != address(0)) return;
        bps = uint16(bound(bps, 0, 10_000));
        bondAmount = bound(bondAmount, 0, 1_000e18);
        vm.prank(s.owner);
        lease.setTerms(
            t,
            bps,
            open ? SeatLease.Mode.Open : SeatLease.Mode.Permissioned,
            s.allowedOperator,
            bondAmount,
            address(0),
            bytes32(0),
            "inv"
        );
    }

    function take(uint256 actorSeed, uint256 tokenSeed) external {
        address a = _actor(actorSeed);
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0) || s.operator != address(0)) return;
        if (block.timestamp < s.termsActiveAt) return;
        if (s.mode == SeatLease.Mode.Permissioned && s.allowedOperator != a) return;
        vm.startPrank(a);
        bond.approve(address(lease), s.bondAmount);
        uint256 before = bond.balanceOf(address(lease));
        lease.take(t);
        ghostBondIn += bond.balanceOf(address(lease)) - before;
        vm.stopPrank();
    }

    function quit(uint256 tokenSeed) external {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.operator == address(0)) return;
        uint256 before = bond.balanceOf(address(lease));
        vm.prank(s.operator);
        lease.quit(t);
        ghostBondOut += before - bond.balanceOf(address(lease));
    }

    function cut(uint256 tokenSeed) external {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.operator == address(0)) return;
        uint256 before = bond.balanceOf(address(lease));
        vm.prank(s.owner);
        lease.cut(t);
        ghostBondOut += before - bond.balanceOf(address(lease));
        cutCalls++;
    }

    function withdraw(uint256 tokenSeed) external {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0) || s.operator != address(0)) return;
        vm.prank(s.owner);
        lease.withdraw(t);
        withdrawCalls++;
    }

    function credit(uint256 actorSeed, uint256 tokenSeed, uint256 amount, bool eth) external {
        address a = _actor(actorSeed);
        uint256 t = _token(tokenSeed);
        if (lease.seat(t).owner == address(0)) return;
        vm.startPrank(a);
        if (eth) {
            amount = bound(amount, 1, 10 ether);
            lease.credit{value: amount}(t, address(0), amount);
            ghostEthCredited += amount;
        } else {
            amount = bound(amount, 1, 1_000e18);
            reward.approve(address(lease), amount);
            lease.credit(t, address(reward), amount);
            ghostCredited += amount;
        }
        vm.stopPrank();
    }

    function claim(uint256 tokenSeed, uint256 amount, uint256 ethAmount) external {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0)) return;
        amount = bound(amount, 0, 1_000e18);
        ethAmount = bound(ethAmount, 0, 1 ether);
        reward.mint(address(distributor), amount);
        vm.deal(address(distributor), address(distributor).balance + ethAmount);
        distributor.setReward(lease.holderOf(t), amount, ethAmount);
        // The reward token is listed twice and ETH once: a repeated entry must be booked only once.
        address[] memory tokens = new address[](3);
        tokens[0] = address(reward);
        tokens[1] = address(0);
        tokens[2] = address(reward);
        vm.prank(s.owner);
        lease.claim(t, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        ghostCredited += amount;
        ghostEthCredited += ethAmount;
    }

    /// @dev Pays the seat's wallet directly, as a third-party claim or a plain transfer would, then skims it.
    function skim(uint256 tokenSeed, uint256 amount, bool eth) external {
        uint256 t = _token(tokenSeed);
        if (lease.seat(t).owner == address(0)) return;
        address holder = lease.holderOf(t);
        if (eth) {
            amount = bound(amount, 1, 10 ether);
            vm.deal(holder, holder.balance + amount);
            lease.skim(t, address(0));
            ghostEthCredited += amount;
        } else {
            amount = bound(amount, 1, 1_000e18);
            reward.mint(holder, amount);
            lease.skim(t, address(reward));
            ghostCredited += amount;
        }
    }

    function sweep(uint256 tokenSeed, bool eth) external {
        uint256 t = _token(tokenSeed);
        address token = eth ? address(0) : address(reward);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0)) return;
        uint256 amount = lease.share(t, token, s.owner);
        if (s.operator != address(0) && s.operator != s.owner) amount += lease.share(t, token, s.operator);
        if (amount == 0) return;
        lease.sweep(t, token);
        if (eth) ghostEthSwept += amount;
        else ghostSwept += amount;
        sweepCalls++;
    }

    function sweepFor(uint256 actorSeed, uint256 tokenSeed, bool eth) external {
        address a = _actor(actorSeed);
        uint256 t = _token(tokenSeed);
        address token = eth ? address(0) : address(reward);
        uint256 amount = lease.share(t, token, a);
        if (amount == 0) return;
        lease.sweepFor(t, token, a);
        if (eth) ghostEthSwept += amount;
        else ghostSwept += amount;
        sweepCalls++;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokenIds.length;
    }
}

contract SeatLeaseInvariantTest is StdInvariant, Test {
    SeatLease lease;
    MockSeatNFT nft;
    MockERC20 bond;
    MockERC20 reward;
    MockDistributor distributor;
    Handler handler;

    function setUp() public {
        nft = new MockSeatNFT();
        bond = new MockERC20("Bond", "BOND");
        reward = new MockERC20("Reward", "RWD");
        distributor = new MockDistributor(address(reward));
        lease = new SeatLease(address(nft), address(bond), "IdentityMD Worker", "2");
        handler = new Handler(lease, nft, bond, reward, distributor);
        targetContract(address(handler));
    }

    /// @dev A seat's holder owns the token exactly when the seat is deposited; nothing else ever moves it, and the
    ///      registry itself never holds a seat.
    function invariant_nftHeldIffDeposited() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            uint256 t = handler.tokenIds(i);
            bool deposited = lease.seat(t).owner != address(0);
            address holder = lease.holderOf(t);
            assertEq(holder != address(0) && nft.ownerOf(t) == holder, deposited, "custody mismatch");
            assertTrue(nft.ownerOf(t) != address(lease), "registry holds a seat");
        }
    }

    /// @dev Every booked unit is owed to exactly one account: per seat and token, the shares sum to `credited`.
    function invariant_sharesSumToCredited() public view {
        address[2] memory tokens = [address(reward), address(0)];
        for (uint256 i; i < handler.tokenCount(); ++i) {
            uint256 t = handler.tokenIds(i);
            for (uint256 k; k < tokens.length; ++k) {
                uint256 sum;
                for (uint256 j; j < handler.actorCount(); ++j) {
                    sum += lease.share(t, tokens[k], handler.actors(j));
                }
                assertEq(sum, lease.credited(t, tokens[k]), "shares != credited");
            }
        }
    }

    /// @dev Swept never exceeds credited, for ETH and ERC-20, and the difference is exactly what is still booked.
    function invariant_sweptNeverExceedsCredited() public view {
        assertLe(handler.ghostSwept(), handler.ghostCredited(), "erc20 over-swept");
        assertLe(handler.ghostEthSwept(), handler.ghostEthCredited(), "eth over-swept");
        assertEq(lease.totalCredited(address(reward)), handler.ghostCredited() - handler.ghostSwept());
        assertEq(lease.totalCredited(address(0)), handler.ghostEthCredited() - handler.ghostEthSwept());
    }

    /// @dev The registry always holds what it owes: booked rewards, live bonds, and escrowed bonds.
    function invariant_solvent() public view {
        assertGe(reward.balanceOf(address(lease)), lease.totalCredited(address(reward)), "reward insolvent");
        assertGe(address(lease).balance, lease.totalCredited(address(0)), "eth insolvent");
        uint256 heldBonds;
        for (uint256 i; i < handler.tokenCount(); ++i) {
            heldBonds += lease.seat(handler.tokenIds(i)).bondHeld;
        }
        assertEq(bond.balanceOf(address(lease)), heldBonds, "bond balance != held bonds");
        assertEq(handler.ghostBondIn() - handler.ghostBondOut(), heldBonds, "bond flow mismatch");
    }

    /// @dev A vacant seat never holds a bond; an occupied Permissioned seat holds none either.
    function invariant_bondOnlyWhileOccupied() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            SeatLease.Seat memory s = lease.seat(handler.tokenIds(i));
            if (s.operator == address(0)) assertEq(s.bondHeld, 0, "vacant seat holds bond");
            if (s.mode == SeatLease.Mode.Permissioned) assertEq(s.bondHeld, 0, "permissioned bond");
        }
    }
}
