// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SeatLease} from "../../src/SeatLease.sol";
import {MockSeatNFT} from "../../src/mocks/MockSeatNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockDistributor} from "../../src/mocks/MockDistributor.sol";

/// @dev Shared fixture: one registry over a mock seat NFT and mock bond token, plus signing helpers.
abstract contract Base is Test {
    string internal constant WORKER_NAME = "IdentityMD Worker";
    string internal constant WORKER_VERSION = "2";
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    MockSeatNFT internal nft;
    MockERC20 internal bond;
    MockERC20 internal reward;
    MockDistributor internal distributor;
    SeatLease internal lease;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal operator;
    uint256 internal operatorKey;
    address internal oracle;
    uint256 internal oracleKey;

    uint256 internal constant TOKEN_ID = 7;
    uint256 internal constant BOND_AMOUNT = 100e18;
    bytes32 internal constant QUESTION = keccak256("did the operator misbehave?");

    function setUp() public virtual {
        (operator, operatorKey) = makeAddrAndKey("operator");
        (oracle, oracleKey) = makeAddrAndKey("oracle");
        nft = new MockSeatNFT();
        bond = new MockERC20("Bond", "BOND");
        reward = new MockERC20("Reward", "RWD");
        distributor = new MockDistributor(address(reward));
        lease = new SeatLease(address(nft), address(bond), WORKER_NAME, WORKER_VERSION);

        nft.mint(owner, TOKEN_ID);
        bond.mint(operator, 10 * BOND_AMOUNT);
        bond.mint(stranger, 10 * BOND_AMOUNT);
        vm.deal(owner, 100 ether);
        vm.deal(operator, 100 ether);
        vm.deal(stranger, 100 ether);
        vm.warp(1_800_000_000);
    }

    // ------------------------------------------------------------------ seat helpers

    function _deposit(uint16 bps, SeatLease.Mode mode, address allowed, uint256 bondAmount, address signer) internal {
        vm.startPrank(owner);
        nft.approve(address(lease), TOKEN_ID);
        lease.deposit(TOKEN_ID, bps, mode, allowed, bondAmount, signer, QUESTION, "seat 7 for lease");
        vm.stopPrank();
    }

    function _depositOpen(uint16 bps) internal {
        _deposit(bps, SeatLease.Mode.Open, address(0), BOND_AMOUNT, oracle);
    }

    function _depositPermissioned(uint16 bps) internal {
        _deposit(bps, SeatLease.Mode.Permissioned, operator, 0, oracle);
    }

    function _takeOpen() internal {
        vm.startPrank(operator);
        bond.approve(address(lease), BOND_AMOUNT);
        lease.take(TOKEN_ID);
        vm.stopPrank();
    }

    function _takePermissioned() internal {
        vm.prank(operator);
        lease.take(TOKEN_ID);
    }

    // ------------------------------------------------------------------ signing helpers

    function _auth(uint256 tokenId, uint64 expiresAt) internal view returns (SeatLease.WorkerAuthorization memory) {
        return SeatLease.WorkerAuthorization({
            deviceKey: keccak256("device"),
            wallet: address(lease),
            tokenId: tokenId,
            nonce: keccak256("nonce"),
            expiresAt: expiresAt,
            relayOrigin: "https://relay.identitymd.example"
        });
    }

    /// @dev Independent recomputation of the network digest, so the test does not trust the contract's own hash.
    function _workerDigest(SeatLease.WorkerAuthorization memory a) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(WORKER_NAME)),
                keccak256(bytes(WORKER_VERSION)),
                block.chainid,
                address(nft)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "WorkerAuthorization(bytes32 deviceKey,address wallet,uint256 tokenId,bytes32 nonce,uint64 expiresAt,string relayOrigin)"
                ),
                a.deviceKey,
                a.wallet,
                a.tokenId,
                a.nonce,
                a.expiresAt,
                keccak256(bytes(a.relayOrigin))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _encode1271(SeatLease.WorkerAuthorization memory a, bytes memory operatorSignature)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(a.deviceKey, a.wallet, a.tokenId, a.nonce, a.expiresAt, a.relayOrigin, operatorSignature);
    }

    function _attestation(bytes32 requestId, bytes32 questionHash, uint8 answerType, bytes memory answer)
        internal
        view
        returns (SeatLease.OracleAttestation memory)
    {
        return SeatLease.OracleAttestation({
            requestId: requestId,
            chainId: block.chainid,
            questionHash: questionHash,
            answerType: answerType,
            answer: answer,
            figure: 0,
            fromBlock: uint64(block.number > 10 ? block.number - 10 : 0),
            toBlock: uint64(block.number),
            blockHash: blockhash(block.number - 1),
            panelJobId: keccak256("panel"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _goodAttestation(bytes32 requestId) internal view returns (SeatLease.OracleAttestation memory) {
        return _attestation(requestId, QUESTION, lease.ANSWER_TYPE_BOOL(), abi.encode(true));
    }

    /// @dev Independent recomputation of the oracle digest under this registry's domain.
    function _oracleDigest(SeatLease.OracleAttestation memory a) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("1"), block.chainid, address(lease)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint64 issuedAt,uint64 expiresAt)"
                ),
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.issuedAt,
                a.expiresAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signAttestation(uint256 key, SeatLease.OracleAttestation memory a) internal view returns (bytes memory) {
        return _sign(key, _oracleDigest(a));
    }
}
