// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./utils/Base.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev ERC-1271 pairing signatures and oracle-attested cuts.
contract SeatLeaseSignaturesTest is Base {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant FAIL = 0xffffffff;

    uint64 internal expiry;

    function setUp() public override {
        super.setUp();
        expiry = uint64(block.timestamp + 1 days);
        _depositOpen(5000);
        _takeOpen();
    }

    // ------------------------------------------------------------------ isValidSignature

    function _validBlob() internal view returns (bytes32 digest, bytes memory blob) {
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        digest = _workerDigest(a);
        blob = _encode1271(a, _sign(operatorKey, digest));
    }

    function test_isValidSignature_acceptsOperatorSignedAuthorization() public view {
        (bytes32 digest, bytes memory blob) = _validBlob();
        assertEq(lease.isValidSignature(digest, blob), MAGIC);
        // The contract's own digest helper agrees with the independent computation.
        assertEq(lease.hashWorkerAuthorization(_auth(TOKEN_ID, expiry)), digest);
    }

    function test_isValidSignature_domainMatchesNetworkParameters() public view {
        bytes32 expected = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(WORKER_NAME)),
                keccak256(bytes(WORKER_VERSION)),
                block.chainid,
                address(nft)
            )
        );
        assertEq(lease.workerDomainSeparator(), expected);
    }

    function test_isValidSignature_rejectsWrongWallet() public view {
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        a.wallet = operator;
        bytes32 digest = _workerDigest(a);
        assertEq(lease.isValidSignature(digest, _encode1271(a, _sign(operatorKey, digest))), FAIL);
    }

    function test_isValidSignature_rejectsWrongTokenId() public {
        // Operator of seat 7 signs for seat 8, which is deposited but operated by someone else.
        nft.mint(owner, 8);
        vm.startPrank(owner);
        nft.approve(address(lease), 8);
        lease.deposit(8, 5000, SeatLease.Mode.Permissioned, stranger, 0, address(0), bytes32(0), "");
        vm.stopPrank();
        vm.prank(stranger);
        lease.take(8);

        SeatLease.WorkerAuthorization memory a = _auth(8, expiry);
        bytes32 digest = _workerDigest(a);
        assertEq(lease.isValidSignature(digest, _encode1271(a, _sign(operatorKey, digest))), FAIL);
        // ... and the other way round: seat 8's operator cannot pair seat 7.
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        SeatLease.WorkerAuthorization memory b = _auth(TOKEN_ID, expiry);
        bytes32 digestB = _workerDigest(b);
        assertEq(lease.isValidSignature(digestB, _encode1271(b, _sign(strangerKey, digestB))), FAIL);
    }

    function test_isValidSignature_rejectsCrossSeatReplayOfBlob() public view {
        // A valid blob for seat 7 presented with seat 8's digest fails the digest check.
        (, bytes memory blob) = _validBlob();
        bytes32 otherDigest = _workerDigest(_auth(8, expiry));
        assertEq(lease.isValidSignature(otherDigest, blob), FAIL);
    }

    function test_isValidSignature_rejectsNonOperatorSigner() public {
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        bytes32 digest = _workerDigest(a);
        assertEq(lease.isValidSignature(digest, _encode1271(a, _sign(strangerKey, digest))), FAIL);
        // The seat owner is not the operator either.
        (, uint256 ownerKey) = makeAddrAndKey("owner");
        assertEq(lease.isValidSignature(digest, _encode1271(a, _sign(ownerKey, digest))), FAIL);
    }

    function test_isValidSignature_rejectsExpired() public {
        (bytes32 digest, bytes memory blob) = _validBlob();
        vm.warp(expiry);
        assertEq(lease.isValidSignature(digest, blob), FAIL);
        vm.warp(expiry - 1);
        assertEq(lease.isValidSignature(digest, blob), MAGIC);
    }

    function test_isValidSignature_rejectsDigestMismatch() public view {
        (bytes32 digest, bytes memory blob) = _validBlob();
        assertEq(lease.isValidSignature(bytes32(uint256(digest) ^ 1), blob), FAIL);
        // Signing an arbitrary hash and presenting it does not work either: the blob must reproduce it.
        bytes32 arbitrary = keccak256("permit or anything else");
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        assertEq(lease.isValidSignature(arbitrary, _encode1271(a, _sign(operatorKey, arbitrary))), FAIL);
    }

    function test_isValidSignature_rejectsVacantSeat() public {
        (bytes32 digest, bytes memory blob) = _validBlob();
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        assertEq(lease.isValidSignature(digest, blob), FAIL);
        // Undeposited seat.
        SeatLease.WorkerAuthorization memory a = _auth(99, expiry);
        bytes32 d = _workerDigest(a);
        assertEq(lease.isValidSignature(d, _encode1271(a, _sign(operatorKey, d))), FAIL);
    }

    function test_isValidSignature_rejectsAfterCut() public {
        (bytes32 digest, bytes memory blob) = _validBlob();
        vm.prank(owner);
        lease.cut(TOKEN_ID);
        assertEq(lease.isValidSignature(digest, blob), FAIL);
    }

    function test_isValidSignature_rejectsOtherChain() public {
        (bytes32 digest, bytes memory blob) = _validBlob();
        vm.chainId(block.chainid + 1);
        assertEq(lease.isValidSignature(digest, blob), FAIL);
    }

    function test_isValidSignature_rejectsMalformedBytes() public view {
        (bytes32 digest, bytes memory blob) = _validBlob();
        assertEq(lease.isValidSignature(digest, ""), FAIL);
        assertEq(lease.isValidSignature(digest, hex"deadbeef"), FAIL);
        assertEq(lease.isValidSignature(digest, new bytes(32 * 7)), FAIL);
        // Truncated valid blob.
        bytes memory truncated = new bytes(blob.length - 40);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = blob[i];
        }
        assertEq(lease.isValidSignature(digest, truncated), FAIL);
        // expiresAt that does not fit uint64.
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        bytes memory bad = abi.encode(
            a.deviceKey,
            a.wallet,
            a.tokenId,
            a.nonce,
            uint256(type(uint64).max) + 1,
            a.relayOrigin,
            _sign(operatorKey, digest)
        );
        assertEq(lease.isValidSignature(digest, bad), FAIL);
    }

    function test_isValidSignature_rejectsBadOperatorSignatures() public view {
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        bytes32 digest = _workerDigest(a);
        // Wrong length.
        assertEq(lease.isValidSignature(digest, _encode1271(a, hex"01")), FAIL);
        assertEq(lease.isValidSignature(digest, _encode1271(a, "")), FAIL);
        // Malleable high-s form of a valid signature.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, digest);
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(uint256(n) - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        assertEq(lease.isValidSignature(digest, _encode1271(a, abi.encodePacked(r, sHigh, vFlip))), FAIL);
        // Garbage 65 bytes recovering to a random address.
        assertEq(lease.isValidSignature(digest, _encode1271(a, abi.encodePacked(r, s, uint8(29)))), FAIL);
    }

    function test_decodeAuthorization_roundTrips() public view {
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        bytes memory sig = hex"aabbcc";
        (SeatLease.WorkerAuthorization memory back, bytes memory sigBack) =
            lease.decodeAuthorization(_encode1271(a, sig));
        assertEq(back.deviceKey, a.deviceKey);
        assertEq(back.wallet, a.wallet);
        assertEq(back.tokenId, a.tokenId);
        assertEq(back.nonce, a.nonce);
        assertEq(back.expiresAt, a.expiresAt);
        assertEq(back.relayOrigin, a.relayOrigin);
        assertEq(sigBack, sig);
    }

    function testFuzz_isValidSignature_onlyOperatorKeyPasses(uint256 key) public view {
        key = bound(key, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        SeatLease.WorkerAuthorization memory a = _auth(TOKEN_ID, expiry);
        bytes32 digest = _workerDigest(a);
        bytes4 result = lease.isValidSignature(digest, _encode1271(a, _sign(key, digest)));
        assertEq(result, key == operatorKey ? MAGIC : FAIL);
    }

    function testFuzz_isValidSignature_arbitraryBytesNeverPass(bytes calldata junk, bytes32 hash) public view {
        assertEq(lease.isValidSignature(hash, junk), FAIL);
    }

    // ------------------------------------------------------------------ cutByOracle

    function test_cutByOracle_forfeitsBondToOwner() public {
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req-1"));
        bytes memory sig = _signAttestation(oracleKey, att);
        assertEq(lease.hashOracleAttestation(att), _oracleDigest(att));
        assertEq(
            lease.oracleDomainSeparator(),
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256("IdentityMD Oracle"),
                    keccak256("1"),
                    block.chainid,
                    address(lease)
                )
            )
        );

        vm.prank(stranger);
        vm.expectEmit(address(lease));
        emit SeatLease.SeatCutByOracle(TOKEN_ID, operator, att.requestId, BOND_AMOUNT);
        lease.cutByOracle(TOKEN_ID, att, sig);

        SeatLease.Seat memory s = lease.seat(TOKEN_ID);
        assertEq(s.operator, address(0));
        assertEq(s.bondHeld, 0);
        assertEq(bond.balanceOf(owner), BOND_AMOUNT);
        assertEq(bond.balanceOf(address(lease)), 0);
        assertTrue(lease.usedRequest(att.requestId));
    }

    function test_cutByOracle_replayIsRejected() public {
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req-1"));
        bytes memory sig = _signAttestation(oracleKey, att);
        lease.cutByOracle(TOKEN_ID, att, sig);
        // Operator comes back.
        _takeOpen();
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleRequestUsed.selector, att.requestId));
        lease.cutByOracle(TOKEN_ID, att, sig);
        // A fresh request id works again.
        SeatLease.OracleAttestation memory att2 = _goodAttestation(keccak256("req-2"));
        lease.cutByOracle(TOKEN_ID, att2, _signAttestation(oracleKey, att2));
        assertEq(bond.balanceOf(owner), 2 * BOND_AMOUNT);
    }

    function test_cutByOracle_rejectsWrongSigner() public {
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        (address impostor, uint256 impostorKey) = makeAddrAndKey("impostor");
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleSignerMismatch.selector, oracle, impostor));
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(impostorKey, att));
        // The operator signing its own cut does not count either.
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleSignerMismatch.selector, oracle, operator));
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(operatorKey, att));
    }

    function test_cutByOracle_rejectsMalformedSignature() public {
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 3));
        lease.cutByOracle(TOKEN_ID, att, hex"010203");
    }

    function test_cutByOracle_rejectsTamperedAttestation() public {
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes memory sig = _signAttestation(oracleKey, att);
        att.figure = 42; // any field change breaks the signature
        vm.expectRevert();
        lease.cutByOracle(TOKEN_ID, att, sig);
    }

    function test_cutByOracle_rejectsWrongQuestion() public {
        SeatLease.OracleAttestation memory att =
            _attestation(keccak256("req"), keccak256("other question"), lease.ANSWER_TYPE_BOOL(), abi.encode(true));
        vm.expectRevert(
            abi.encodeWithSelector(SeatLease.OracleQuestionMismatch.selector, QUESTION, keccak256("other question"))
        );
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
    }

    function test_cutByOracle_rejectsWrongChainId() public {
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        att.chainId = block.chainid + 1;
        vm.expectRevert(
            abi.encodeWithSelector(SeatLease.OracleChainMismatch.selector, block.chainid, block.chainid + 1)
        );
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
    }

    function test_cutByOracle_rejectsFalseAnswer() public {
        SeatLease.OracleAttestation memory att =
            _attestation(keccak256("req"), QUESTION, lease.ANSWER_TYPE_BOOL(), abi.encode(false));
        vm.expectRevert(SeatLease.OracleAnswerNotTrue.selector);
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
    }

    function test_cutByOracle_rejectsOddAnswerEncodings() public {
        SeatLease.OracleAttestation memory att =
            _attestation(keccak256("req"), QUESTION, lease.ANSWER_TYPE_BOOL(), abi.encode(uint256(2)));
        vm.expectRevert(SeatLease.OracleAnswerNotTrue.selector);
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
        att = _attestation(keccak256("req"), QUESTION, lease.ANSWER_TYPE_BOOL(), hex"01");
        vm.expectRevert(SeatLease.OracleAnswerNotTrue.selector);
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
        att = _attestation(keccak256("req"), QUESTION, lease.ANSWER_TYPE_BOOL(), "");
        vm.expectRevert(SeatLease.OracleAnswerNotTrue.selector);
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
    }

    function test_cutByOracle_rejectsNonBoolType() public {
        SeatLease.OracleAttestation memory att = _attestation(keccak256("req"), QUESTION, 2, abi.encode(true));
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleAnswerNotBool.selector, uint8(2)));
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
    }

    function test_cutByOracle_rejectsExpired() public {
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes memory sig = _signAttestation(oracleKey, att);
        vm.warp(att.expiresAt);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleAttestationExpired.selector, att.expiresAt));
        lease.cutByOracle(TOKEN_ID, att, sig);
        vm.warp(att.expiresAt - 1);
        lease.cutByOracle(TOKEN_ID, att, sig);
        assertEq(lease.seat(TOKEN_ID).operator, address(0));
    }

    function test_cutByOracle_rejectsVacantAndUndeposited() public {
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes memory sig = _signAttestation(oracleKey, att);
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatVacant.selector, TOKEN_ID));
        lease.cutByOracle(TOKEN_ID, att, sig);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.SeatNotDeposited.selector, 99));
        lease.cutByOracle(99, att, sig);
    }

    function test_cutByOracle_rejectsSeatWithoutOracle() public {
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 5000, SeatLease.Mode.Open, address(0), BOND_AMOUNT, address(0), QUESTION, "");
        _takeOpen();
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        vm.expectRevert(abi.encodeWithSelector(SeatLease.NoOracle.selector, TOKEN_ID));
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
    }

    function test_cutByOracle_attestationForAnotherRegistryIsRejected() public {
        // Same oracle, same question, but signed under a different registry's domain.
        SeatLease other = new SeatLease(address(nft), address(bond), WORKER_NAME, WORKER_VERSION);
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes memory sig = _sign(oracleKey, other.hashOracleAttestation(att));
        assertTrue(other.hashOracleAttestation(att) != lease.hashOracleAttestation(att));
        address recovered = ECDSA.recover(lease.hashOracleAttestation(att), sig);
        vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleSignerMismatch.selector, oracle, recovered));
        lease.cutByOracle(TOKEN_ID, att, sig);
    }

    function test_cutByOracle_permissionedSeatForfeitsNothing() public {
        vm.prank(operator);
        lease.quit(TOKEN_ID);
        vm.prank(owner);
        lease.setTerms(TOKEN_ID, 5000, SeatLease.Mode.Permissioned, operator, 0, oracle, QUESTION, "");
        _takePermissioned();
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        vm.expectEmit(address(lease));
        emit SeatLease.SeatCutByOracle(TOKEN_ID, operator, att.requestId, 0);
        lease.cutByOracle(TOKEN_ID, att, _signAttestation(oracleKey, att));
        assertEq(bond.balanceOf(owner), 0);
    }

    function testFuzz_cutByOracle_onlyOracleKeyPasses(uint256 key) public {
        key = bound(key, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        SeatLease.OracleAttestation memory att = _goodAttestation(keccak256("req"));
        bytes memory sig = _signAttestation(key, att);
        if (key != oracleKey) {
            vm.expectRevert(abi.encodeWithSelector(SeatLease.OracleSignerMismatch.selector, oracle, vm.addr(key)));
        }
        lease.cutByOracle(TOKEN_ID, att, sig);
    }
}
