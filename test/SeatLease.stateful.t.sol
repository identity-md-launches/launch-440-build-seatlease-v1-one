// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {MockSeatNFT} from "../src/mocks/MockSeatNFT.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockDistributor} from "../src/mocks/MockDistributor.sol";

/// @dev Second, wider handler: three keyed actors that can be owner, operator or payer of any of three seats;
///      every state transition of the registry including oracle cuts with real signatures and term changes;
///      three reward assets (the reward ERC-20, the bond ERC-20 used as a reward, and ETH); unbooked donations.
///      Ghost variables record, per seat and per asset, what was booked and what was swept, and every custody
///      change of the seat NFTs is attributed to the call that caused it.
contract StatefulHandler is Test {
    SeatLease public lease;
    MockSeatNFT public nft;
    MockERC20 public bond;
    MockERC20 public reward;
    MockDistributor public distributor;

    address[] public actors;
    uint256[] public actorKeys;
    uint256[] public tokenIds;
    address[] public assets;

    address public oracle;
    uint256 internal oracleKey;
    uint256 internal requestNonce;
    bytes32[] public usedRequests;

    // per-asset ghosts
    mapping(address => uint256) public ghostCredited;
    mapping(address => uint256) public ghostSwept;
    mapping(address => uint256) public ghostDonated;
    // per-seat ghosts
    mapping(uint256 => mapping(address => uint256)) public ghostSeatCredited;
    mapping(uint256 => mapping(address => uint256)) public ghostSeatSwept;
    // bond ghosts
    uint256 public ghostBondIn;
    uint256 public ghostBondReturned;
    uint256 public ghostBondForfeited;
    // custody ghosts
    uint256 public withdrawCalls;
    uint256 public nftExits;
    uint256 public nftEntries;
    uint256 public depositCalls;
    bool public exitWhileOccupied;
    bool public exitOutsideWithdraw;
    bool internal inWithdraw;
    // call counters, so the suite can see every path was exercised
    uint256 public oracleCuts;
    uint256 public ownerCuts;
    uint256 public quits;
    uint256 public claims;
    uint256 public termChanges;

    constructor(SeatLease lease_, MockSeatNFT nft_, MockERC20 bond_, MockERC20 reward_, MockDistributor d) {
        lease = lease_;
        nft = nft_;
        bond = bond_;
        reward = reward_;
        distributor = d;
        (oracle, oracleKey) = makeAddrAndKey("stateful-oracle");
        for (uint256 i; i < 3; ++i) {
            (address a, uint256 k) = makeAddrAndKey(string.concat("stateful-actor-", vm.toString(i)));
            actors.push(a);
            actorKeys.push(k);
            vm.deal(a, 10_000 ether);
            bond.mint(a, 1_000_000e18);
            reward.mint(a, 1_000_000e18);
        }
        for (uint256 t = 11; t <= 13; ++t) {
            tokenIds.push(t);
            nft.mint(actors[t % actors.length], t);
        }
        assets.push(address(reward));
        assets.push(address(bond));
        assets.push(address(0));
    }

    // ------------------------------------------------------------------ custody tracking

    modifier tracked() {
        uint256 n = tokenIds.length;
        bool[] memory heldBefore = new bool[](n);
        bool[] memory occupiedBefore = new bool[](n);
        for (uint256 i; i < n; ++i) {
            heldBefore[i] = nft.ownerOf(tokenIds[i]) == address(lease);
            occupiedBefore[i] = lease.seat(tokenIds[i]).operator != address(0);
        }
        _;
        for (uint256 i; i < n; ++i) {
            bool heldAfter = nft.ownerOf(tokenIds[i]) == address(lease);
            if (heldBefore[i] && !heldAfter) {
                nftExits++;
                if (occupiedBefore[i]) exitWhileOccupied = true;
                if (!inWithdraw) exitOutsideWithdraw = true;
            }
            if (!heldBefore[i] && heldAfter) nftEntries++;
        }
        inWithdraw = false;
    }

    function _actor(uint256 seed) internal view returns (address, uint256) {
        uint256 i = seed % actors.length;
        return (actors[i], actorKeys[i]);
    }

    function _token(uint256 seed) internal view returns (uint256) {
        return tokenIds[seed % tokenIds.length];
    }

    function _asset(uint256 seed) internal view returns (address) {
        return assets[seed % assets.length];
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(lease).balance : MockERC20(asset).balanceOf(address(lease));
    }

    // ------------------------------------------------------------------ lifecycle

    function deposit(uint256 actorSeed, uint256 tokenSeed, uint16 bps, uint8 mode, uint256 bondAmount, bool withOracle)
        external
        tracked
    {
        (address a,) = _actor(actorSeed);
        uint256 t = _token(tokenSeed);
        if (nft.ownerOf(t) != a) return;
        bps = uint16(bound(bps, 0, 10_000));
        bondAmount = bound(bondAmount, 0, 1_000e18);
        (address allowed,) = _actor((actorSeed % actors.length) + 1);
        vm.startPrank(a);
        nft.approve(address(lease), t);
        lease.deposit(
            t,
            bps,
            mode % 2 == 0 ? SeatLease.Mode.Open : SeatLease.Mode.Permissioned,
            allowed,
            bondAmount,
            withOracle ? oracle : address(0),
            keccak256(abi.encode("question", t)),
            "stateful"
        );
        vm.stopPrank();
        depositCalls++;
    }

    function setTerms(
        uint256 tokenSeed,
        uint16 bps,
        uint8 mode,
        uint256 bondAmount,
        bool withOracle,
        uint256 allowedSeed
    ) external tracked {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0) || s.operator != address(0)) return;
        bps = uint16(bound(bps, 0, 10_000));
        bondAmount = bound(bondAmount, 0, 1_000e18);
        (address allowed,) = _actor(allowedSeed);
        vm.prank(s.owner);
        lease.setTerms(
            t,
            bps,
            mode % 2 == 0 ? SeatLease.Mode.Open : SeatLease.Mode.Permissioned,
            allowed,
            bondAmount,
            withOracle ? oracle : address(0),
            keccak256(abi.encode("question", t)),
            ""
        );
        termChanges++;
    }

    function take(uint256 actorSeed, uint256 tokenSeed) external tracked {
        (address a,) = _actor(actorSeed);
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0) || s.operator != address(0)) return;
        if (s.mode == SeatLease.Mode.Permissioned && s.allowedOperator != a) return;
        uint256 before = bond.balanceOf(address(lease));
        vm.startPrank(a);
        bond.approve(address(lease), s.bondAmount);
        lease.take(t);
        vm.stopPrank();
        ghostBondIn += bond.balanceOf(address(lease)) - before;
    }

    function quit(uint256 tokenSeed) external tracked {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.operator == address(0)) return;
        uint256 before = bond.balanceOf(s.operator);
        vm.prank(s.operator);
        lease.quit(t);
        ghostBondReturned += bond.balanceOf(s.operator) - before;
        quits++;
    }

    function cut(uint256 tokenSeed) external tracked {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.operator == address(0)) return;
        uint256 before = bond.balanceOf(s.operator);
        vm.prank(s.owner);
        lease.cut(t);
        ghostBondReturned += bond.balanceOf(s.operator) - before;
        ownerCuts++;
    }

    function cutByOracle(uint256 tokenSeed, uint256 callerSeed) external tracked {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.operator == address(0) || s.oracleSigner == address(0)) return;
        SeatLease.OracleAttestation memory att = SeatLease.OracleAttestation({
            requestId: keccak256(abi.encode("request", requestNonce++)),
            chainId: block.chainid,
            questionHash: s.questionHash,
            answerType: 1,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: 0,
            toBlock: uint64(block.number),
            blockHash: bytes32(0),
            panelJobId: bytes32(0),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1)
        });
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(oracleKey, lease.hashOracleAttestation(att));
        (address caller,) = _actor(callerSeed);
        uint256 before = bond.balanceOf(s.owner);
        vm.prank(caller);
        lease.cutByOracle(t, att, abi.encodePacked(r, sg, v));
        ghostBondForfeited += bond.balanceOf(s.owner) - before;
        usedRequests.push(att.requestId);
        oracleCuts++;
    }

    function withdraw(uint256 tokenSeed) external tracked {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0) || s.operator != address(0)) return;
        inWithdraw = true; // cleared by `tracked` after the custody check
        vm.prank(s.owner);
        lease.withdraw(t);
        withdrawCalls++;
    }

    // ------------------------------------------------------------------ rewards

    function credit(uint256 actorSeed, uint256 tokenSeed, uint256 assetSeed, uint256 amount) external tracked {
        (address a,) = _actor(actorSeed);
        uint256 t = _token(tokenSeed);
        address asset = _asset(assetSeed);
        if (lease.seat(t).owner == address(0)) return;
        vm.startPrank(a);
        if (asset == address(0)) {
            amount = bound(amount, 1, 10 ether);
            lease.credit{value: amount}(t, address(0), amount);
        } else {
            amount = bound(amount, 1, 1_000e18);
            MockERC20(asset).approve(address(lease), amount);
            lease.credit(t, asset, amount);
        }
        vm.stopPrank();
        ghostCredited[asset] += amount;
        ghostSeatCredited[t][asset] += amount;
    }

    function claim(uint256 tokenSeed, uint256 amount, uint256 ethAmount, bool listEth) external tracked {
        uint256 t = _token(tokenSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0)) return;
        amount = bound(amount, 0, 1_000e18);
        ethAmount = bound(ethAmount, 0, 1 ether);
        reward.mint(address(distributor), amount);
        vm.deal(address(distributor), address(distributor).balance + ethAmount);
        distributor.setReward(address(lease), amount, ethAmount);
        address[] memory tokens = new address[](listEth ? 2 : 1);
        tokens[0] = address(reward);
        if (listEth) tokens[1] = address(0);
        vm.prank(s.owner);
        lease.claim(t, address(distributor), abi.encodeCall(MockDistributor.claim, ()), tokens);
        ghostCredited[address(reward)] += amount;
        ghostSeatCredited[t][address(reward)] += amount;
        ghostCredited[address(0)] += ethAmount;
        ghostSeatCredited[t][address(0)] += ethAmount;
        claims++;
    }

    function sweep(uint256 tokenSeed, uint256 assetSeed, uint256 callerSeed) external tracked {
        uint256 t = _token(tokenSeed);
        address asset = _asset(assetSeed);
        SeatLease.Seat memory s = lease.seat(t);
        if (s.owner == address(0)) return;
        uint256 amount = lease.credited(t, asset);
        if (amount == 0) return;
        (address caller,) = _actor(callerSeed);
        uint256 ownerBefore = asset == address(0) ? s.owner.balance : MockERC20(asset).balanceOf(s.owner);
        uint256 operatorBefore = s.operator == address(0)
            ? 0
            : (asset == address(0) ? s.operator.balance : MockERC20(asset).balanceOf(s.operator));
        vm.prank(caller);
        lease.sweep(t, asset);
        uint256 ownerGain = (asset == address(0) ? s.owner.balance : MockERC20(asset).balanceOf(s.owner)) - ownerBefore;
        uint256 operatorGain = s.operator == address(0)
            ? 0
            : (asset == address(0) ? s.operator.balance : MockERC20(asset).balanceOf(s.operator)) - operatorBefore;
        // Sweep pays exactly the booked amount, split by the terms in force at sweep time.
        if (s.owner == s.operator) {
            assertEq(ownerGain, amount, "self-operated sweep");
        } else {
            uint256 expectedOwner = s.operator == address(0) ? amount : (amount * s.ownerBps) / 10_000;
            assertEq(ownerGain, expectedOwner, "owner share");
            assertEq(operatorGain, amount - expectedOwner, "operator share");
        }
        ghostSwept[asset] += amount;
        ghostSeatSwept[t][asset] += amount;
    }

    /// @dev Unbooked reward tokens pushed straight to the registry. They belong to nobody and must never be
    ///      swept by anyone, nor break the accounting of what is booked.
    function donate(uint256 amount) external tracked {
        amount = bound(amount, 1, 1_000e18);
        reward.mint(address(lease), amount);
        ghostDonated[address(reward)] += amount;
    }

    // ------------------------------------------------------------------ views

    function tokenCount() external view returns (uint256) {
        return tokenIds.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function usedRequestCount() external view returns (uint256) {
        return usedRequests.length;
    }

    function signAuthorization(uint256 actorIndex, uint256 tokenId) external view returns (bytes32, bytes memory) {
        SeatLease.WorkerAuthorization memory a = SeatLease.WorkerAuthorization({
            deviceKey: keccak256(abi.encode("device", actorIndex)),
            wallet: address(lease),
            tokenId: tokenId,
            nonce: keccak256(abi.encode("nonce", block.timestamp)),
            expiresAt: uint64(block.timestamp + 1),
            relayOrigin: "https://relay.identitymd.example"
        });
        bytes32 digest = lease.hashWorkerAuthorization(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKeys[actorIndex], digest);
        return (
            digest,
            abi.encode(a.deviceKey, a.wallet, a.tokenId, a.nonce, a.expiresAt, a.relayOrigin, abi.encodePacked(r, s, v))
        );
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SeatLeaseStatefulInvariantTest is StdInvariant, Test {
    SeatLease lease;
    MockSeatNFT nft;
    MockERC20 bond;
    MockERC20 reward;
    MockDistributor distributor;
    StatefulHandler handler;

    function setUp() public {
        nft = new MockSeatNFT();
        bond = new MockERC20("Bond", "BOND");
        reward = new MockERC20("Reward", "RWD");
        distributor = new MockDistributor(address(reward));
        lease = new SeatLease(address(nft), address(bond), "IdentityMD Worker", "2");
        handler = new StatefulHandler(lease, nft, bond, reward, distributor);
        targetContract(address(handler));
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(lease).balance : MockERC20(asset).balanceOf(address(lease));
    }

    /// @dev Per asset: the registry's booked total equals the sum of the per-seat bookings, and swept never
    ///      exceeds credited for any seat or in aggregate.
    function invariant_bookedTotalsMatchSeatBookings() public view {
        for (uint256 j; j < handler.assetCount(); ++j) {
            address asset = handler.assets(j);
            uint256 sumSeats;
            for (uint256 i; i < handler.tokenCount(); ++i) {
                uint256 t = handler.tokenIds(i);
                uint256 booked = lease.credited(t, asset);
                sumSeats += booked;
                assertLe(handler.ghostSeatSwept(t, asset), handler.ghostSeatCredited(t, asset), "seat over-swept");
                assertEq(booked, handler.ghostSeatCredited(t, asset) - handler.ghostSeatSwept(t, asset), "seat booked");
            }
            assertEq(lease.totalCredited(asset), sumSeats, "total != sum of seats");
            assertLe(handler.ghostSwept(asset), handler.ghostCredited(asset), "asset over-swept");
        }
    }

    /// @dev The registry always holds what it owes: for the reward token that is bookings plus donations exactly;
    ///      for the bond token bookings plus every live bond; for ETH the bookings exactly.
    function invariant_solventPerAsset() public view {
        uint256 heldBonds;
        for (uint256 i; i < handler.tokenCount(); ++i) {
            heldBonds += lease.seat(handler.tokenIds(i)).bondHeld;
        }
        assertEq(
            reward.balanceOf(address(lease)),
            lease.totalCredited(address(reward)) + handler.ghostDonated(address(reward)),
            "reward balance"
        );
        assertEq(bond.balanceOf(address(lease)), lease.totalCredited(address(bond)) + heldBonds, "bond balance");
        assertEq(address(lease).balance, lease.totalCredited(address(0)), "eth balance");
        assertEq(
            handler.ghostBondIn(), handler.ghostBondReturned() + handler.ghostBondForfeited() + heldBonds, "bond flow"
        );
    }

    /// @dev Bonds are only ever held for an occupied Open seat, and nothing is ever escrowed with a plain token.
    function invariant_bondOnlyForOccupiedOpenSeats() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            SeatLease.Seat memory s = lease.seat(handler.tokenIds(i));
            if (s.operator == address(0) || s.mode == SeatLease.Mode.Permissioned) {
                assertEq(s.bondHeld, 0, "bond without operator");
            }
        }
        for (uint256 i; i < handler.actorCount(); ++i) {
            assertEq(lease.bondOwed(handler.actors(i)), 0, "unexpected escrow");
        }
    }

    /// @dev Every seat NFT is held exactly when its seat is deposited; the only exits are withdrawals of vacant
    ///      seats, and each deposit is one entry.
    function invariant_nftCustody() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            uint256 t = handler.tokenIds(i);
            SeatLease.Seat memory s = lease.seat(t);
            bool held = nft.ownerOf(t) == address(lease);
            assertEq(held, s.owner != address(0), "custody != deposited");
            if (!held) {
                assertEq(s.operator, address(0), "operator on undeposited seat");
                assertEq(s.bondHeld, 0, "bond on undeposited seat");
            }
        }
        assertEq(handler.nftExits(), handler.withdrawCalls(), "nft left outside withdraw");
        assertEq(handler.nftEntries(), handler.depositCalls(), "nft entered outside deposit");
        assertFalse(handler.exitWhileOccupied(), "nft left an occupied seat");
        assertFalse(handler.exitOutsideWithdraw(), "nft left outside withdraw()");
    }

    /// @dev A consumed oracle request never becomes reusable.
    function invariant_usedRequestsStayUsed() public view {
        for (uint256 i; i < handler.usedRequestCount(); ++i) {
            assertTrue(lease.usedRequest(handler.usedRequests(i)), "request forgotten");
        }
    }

    /// @dev ERC-1271 mirrors seat state: a fresh WorkerAuthorization for a seat is accepted exactly when it is
    ///      signed by that seat's current operator, and never for a vacant or undeposited seat.
    function invariant_erc1271MirrorsOperators() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            uint256 t = handler.tokenIds(i);
            address operator = lease.seat(t).operator;
            for (uint256 j; j < handler.actorCount(); ++j) {
                (bytes32 digest, bytes memory blob) = handler.signAuthorization(j, t);
                bytes4 expected =
                    operator != address(0) && handler.actors(j) == operator ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
                assertEq(lease.isValidSignature(digest, blob), expected, "erc1271 disagrees with seat state");
            }
        }
    }
}
