// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SeatLease v1
/// @notice A registry that holds IdentityMD seats (ERC-721) so a seat owner can let an operator run the seat
///         while both share the rewards that the network pays to the seat holder (this contract).
/// @dev No upgradeability, no global admin, no pause, no selfdestruct. Every seat is administered by the
///      address that deposited it. The contract answers ERC-1271 `isValidSignature` for the current operator of
///      the seat named inside the WorkerAuthorization so the network can pair a device to a leased seat.
contract SeatLease is ERC721Holder, IERC1271, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice Who may take a vacant seat.
    enum Mode {
        /// @dev Only `allowedOperator` may take the seat. No bond is pulled.
        Permissioned,
        /// @dev Anyone may take the seat by posting `bondAmount` of the bond token.
        Open
    }

    /// @notice Per-seat state. `owner == address(0)` means the seat is not deposited.
    struct Seat {
        address owner;
        address operator;
        uint16 ownerBps;
        Mode mode;
        address allowedOperator;
        uint256 bondAmount;
        uint256 bondHeld;
        address oracleSigner;
        bytes32 questionHash;
        string listing;
    }

    /// @notice The network's device pairing message. `wallet` must be this contract.
    struct WorkerAuthorization {
        bytes32 deviceKey;
        address wallet;
        uint256 tokenId;
        bytes32 nonce;
        uint64 expiresAt;
        string relayOrigin;
    }

    /// @notice The network oracle's attestation, signed by the seat's `oracleSigner` under this contract's
    ///         "IdentityMD Oracle" / "1" domain.
    struct OracleAttestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    // ---------------------------------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------------------------------

    /// @notice Basis-point denominator for `ownerBps`.
    uint16 public constant BPS = 10_000;
    /// @notice Maximum byte length of a seat listing.
    uint256 public constant MAX_LISTING_BYTES = 280;
    /// @notice `answerType` value the oracle uses for boolean answers.
    uint8 public constant ANSWER_TYPE_BOOL = 1;
    /// @notice ERC-1271 success value.
    bytes4 public constant MAGIC_VALUE = 0x1626ba7e;
    /// @notice ERC-1271 failure value.
    bytes4 public constant FAIL_VALUE = 0xffffffff;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Type hash of the network's WorkerAuthorization struct.
    bytes32 public constant WORKER_AUTHORIZATION_TYPEHASH = keccak256(
        "WorkerAuthorization(bytes32 deviceKey,address wallet,uint256 tokenId,bytes32 nonce,uint64 expiresAt,string relayOrigin)"
    );

    /// @notice Type hash of the network's OracleAttestation struct.
    bytes32 public constant ORACLE_ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint64 issuedAt,uint64 expiresAt)"
    );

    /// @notice The seat NFT this registry holds.
    IERC721 public immutable seatNFT;
    /// @notice The ERC-20 posted as a bond by operators of Open seats.
    IERC20 public immutable bondToken;

    bytes32 private immutable _workerNameHash;
    bytes32 private immutable _workerVersionHash;
    string private _workerName;
    string private _workerVersion;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(uint256 tokenId => Seat) private _seats;
    mapping(uint256 tokenId => mapping(address token => uint256 amount)) private _credited;
    mapping(bytes32 requestId => bool used) private _usedRequests;
    /// @notice Total amount of `token` booked to seats. Backs the `claim` target guard and the sweep invariant.
    mapping(address token => uint256 amount) public totalCredited;
    /// @notice Bond that could not be pushed to `account` and waits for `redeemBond`.
    mapping(address account => uint256 amount) public bondOwed;

    /// @dev Token id whose deposit is in flight; `onERC721Received` accepts only that token from the seat NFT.
    uint256 private _depositing;
    bool private _depositActive;
    /// @dev True while `claim` runs; the only window in which `receive` accepts ETH.
    bool private _claimActive;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event SeatDeposited(uint256 indexed tokenId, address indexed owner);
    event TermsSet(
        uint256 indexed tokenId,
        uint16 ownerBps,
        Mode mode,
        address allowedOperator,
        uint256 bondAmount,
        address oracleSigner,
        bytes32 questionHash,
        string listing
    );
    event SeatTaken(uint256 indexed tokenId, address indexed operator, uint256 bondHeld);
    event SeatQuit(uint256 indexed tokenId, address indexed operator, uint256 bondReturned);
    event SeatCut(uint256 indexed tokenId, address indexed operator, uint256 bondReturned);
    event SeatCutByOracle(
        uint256 indexed tokenId, address indexed operator, bytes32 indexed requestId, uint256 bondForfeited
    );
    event SeatWithdrawn(uint256 indexed tokenId, address indexed owner);
    event Credited(uint256 indexed tokenId, address indexed token, address indexed from, uint256 amount);
    event Claimed(uint256 indexed tokenId, address indexed target, bytes data);
    event Booked(uint256 indexed tokenId, address indexed token, uint256 amount);
    event Swept(
        uint256 indexed tokenId,
        address indexed token,
        address owner,
        uint256 ownerAmount,
        address operator,
        uint256 operatorAmount
    );
    event BondEscrowed(address indexed account, uint256 amount);
    event BondRedeemed(address indexed account, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error NotSeatOwner(uint256 tokenId, address caller);
    error NotOperator(uint256 tokenId, address caller);
    error NotAllowedOperator(uint256 tokenId, address caller);
    error SeatNotDeposited(uint256 tokenId);
    error SeatAlreadyDeposited(uint256 tokenId);
    error SeatNotVacant(uint256 tokenId);
    error SeatVacant(uint256 tokenId);
    error InvalidBps(uint16 ownerBps);
    error ListingTooLong(uint256 length);
    error UnexpectedToken(address collection, uint256 tokenId);
    error NftNotReceived(uint256 tokenId);
    error NftNotHeld(uint256 tokenId);
    error NoOracle(uint256 tokenId);
    error OracleChainMismatch(uint256 expected, uint256 actual);
    error OracleQuestionMismatch(bytes32 expected, bytes32 actual);
    error OracleAnswerNotBool(uint8 answerType);
    error OracleAnswerNotTrue();
    error OracleAttestationExpired(uint64 expiresAt);
    error OracleRequestUsed(bytes32 requestId);
    error OracleSignerMismatch(address expected, address actual);
    error WrongValue(uint256 expected, uint256 actual);
    error ZeroAmount();
    error ForbiddenTarget(address target);
    error ClaimFailed(bytes reason);
    error BookedBalanceDecreased(address token, uint256 before, uint256 afterwards);
    error EthTransferFailed(address to, uint256 amount);
    error NothingOwed(address account);
    error DirectEthNotAccepted();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param seatNFT_ The IdentityMD seat NFT.
    /// @param bondToken_ The ERC-20 operators post as a bond on Open seats.
    /// @param workerDomainName The network's WorkerAuthorization EIP-712 domain name (currently "IdentityMD Worker").
    /// @param workerDomainVersion The network's WorkerAuthorization EIP-712 domain version (currently "2").
    constructor(address seatNFT_, address bondToken_, string memory workerDomainName, string memory workerDomainVersion)
        EIP712("IdentityMD Oracle", "1")
    {
        if (seatNFT_ == address(0) || bondToken_ == address(0)) revert ZeroAddress();
        seatNFT = IERC721(seatNFT_);
        bondToken = IERC20(bondToken_);
        _workerName = workerDomainName;
        _workerVersion = workerDomainVersion;
        _workerNameHash = keccak256(bytes(workerDomainName));
        _workerVersionHash = keccak256(bytes(workerDomainVersion));
    }

    /// @dev Plain ETH is refused so it can never sit unattributed. Use `credit(tokenId, address(0), amount)`.
    ///      The only exception is ETH arriving while `claim` runs: `claim` measures and books every wei of it.
    receive() external payable {
        if (!_claimActive) revert DirectEthNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Seat lifecycle
    // ---------------------------------------------------------------------------------------------

    /// @notice Deposit a seat you own and record its lease terms.
    function deposit(
        uint256 tokenId,
        uint16 ownerBps,
        Mode mode,
        address allowedOperator,
        uint256 bondAmount,
        address oracleSigner,
        bytes32 questionHash,
        string calldata listing
    ) external nonReentrant {
        Seat storage s = _seats[tokenId];
        if (s.owner != address(0)) revert SeatAlreadyDeposited(tokenId);
        if (seatNFT.ownerOf(tokenId) != msg.sender) revert NotSeatOwner(tokenId, msg.sender);

        s.owner = msg.sender;
        emit SeatDeposited(tokenId, msg.sender);
        _setTerms(s, tokenId, ownerBps, mode, allowedOperator, bondAmount, oracleSigner, questionHash, listing);

        _depositing = tokenId;
        _depositActive = true;
        seatNFT.safeTransferFrom(msg.sender, address(this), tokenId);
        _depositActive = false;
        if (seatNFT.ownerOf(tokenId) != address(this)) revert NftNotReceived(tokenId);
    }

    /// @notice Change the terms of a vacant seat you deposited.
    function setTerms(
        uint256 tokenId,
        uint16 ownerBps,
        Mode mode,
        address allowedOperator,
        uint256 bondAmount,
        address oracleSigner,
        bytes32 questionHash,
        string calldata listing
    ) external {
        Seat storage s = _onlyOwner(tokenId);
        if (s.operator != address(0)) revert SeatNotVacant(tokenId);
        _setTerms(s, tokenId, ownerBps, mode, allowedOperator, bondAmount, oracleSigner, questionHash, listing);
    }

    /// @notice Become the operator of a vacant seat. Open seats pull `bondAmount` of the bond token from the caller.
    function take(uint256 tokenId) external nonReentrant {
        Seat storage s = _seats[tokenId];
        if (s.owner == address(0)) revert SeatNotDeposited(tokenId);
        if (s.operator != address(0)) revert SeatNotVacant(tokenId);

        uint256 held = 0;
        if (s.mode == Mode.Permissioned) {
            if (msg.sender != s.allowedOperator) revert NotAllowedOperator(tokenId, msg.sender);
        } else if (s.bondAmount != 0) {
            uint256 before = bondToken.balanceOf(address(this));
            bondToken.safeTransferFrom(msg.sender, address(this), s.bondAmount);
            held = bondToken.balanceOf(address(this)) - before;
        }

        s.operator = msg.sender;
        s.bondHeld = held;
        emit SeatTaken(tokenId, msg.sender, held);
    }

    /// @notice Leave a seat you operate. Your bond is returned.
    function quit(uint256 tokenId) external nonReentrant {
        Seat storage s = _seats[tokenId];
        if (msg.sender != s.operator) revert NotOperator(tokenId, msg.sender);
        uint256 held = _clearOperator(s);
        emit SeatQuit(tokenId, msg.sender, held);
        _payBond(msg.sender, held);
    }

    /// @notice Remove the operator of a seat you deposited. The operator's bond is returned to them.
    function cut(uint256 tokenId) external nonReentrant {
        Seat storage s = _onlyOwner(tokenId);
        address operator = s.operator;
        if (operator == address(0)) revert SeatVacant(tokenId);
        uint256 held = _clearOperator(s);
        emit SeatCut(tokenId, operator, held);
        _payBond(operator, held);
    }

    /// @notice Remove the operator of a seat on the strength of a signed oracle attestation that answers the
    ///         seat's question with `true`. The operator's bond is forfeited to the seat owner.
    function cutByOracle(uint256 tokenId, OracleAttestation calldata attestation, bytes calldata signature)
        external
        nonReentrant
    {
        Seat storage s = _seats[tokenId];
        address operator = s.operator;
        if (s.owner == address(0)) revert SeatNotDeposited(tokenId);
        if (operator == address(0)) revert SeatVacant(tokenId);
        address signer = s.oracleSigner;
        if (signer == address(0)) revert NoOracle(tokenId);
        if (attestation.chainId != block.chainid) revert OracleChainMismatch(block.chainid, attestation.chainId);
        if (attestation.questionHash != s.questionHash) {
            revert OracleQuestionMismatch(s.questionHash, attestation.questionHash);
        }
        if (attestation.answerType != ANSWER_TYPE_BOOL) revert OracleAnswerNotBool(attestation.answerType);
        if (attestation.answer.length != 32 || abi.decode(attestation.answer, (uint256)) != 1) {
            revert OracleAnswerNotTrue();
        }
        if (attestation.expiresAt <= block.timestamp) revert OracleAttestationExpired(attestation.expiresAt);
        if (_usedRequests[attestation.requestId]) revert OracleRequestUsed(attestation.requestId);
        address recovered = ECDSA.recover(hashOracleAttestation(attestation), signature);
        if (recovered != signer) revert OracleSignerMismatch(signer, recovered);

        _usedRequests[attestation.requestId] = true;
        uint256 held = _clearOperator(s);
        emit SeatCutByOracle(tokenId, operator, attestation.requestId, held);
        _payBond(s.owner, held);
    }

    /// @notice Take back a vacant seat you deposited. Sweep any booked balances first; they stay with the tokenId.
    function withdraw(uint256 tokenId) external nonReentrant {
        Seat storage s = _onlyOwner(tokenId);
        if (s.operator != address(0)) revert SeatNotVacant(tokenId);
        delete _seats[tokenId];
        emit SeatWithdrawn(tokenId, msg.sender);
        seatNFT.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Rewards
    // ---------------------------------------------------------------------------------------------

    /// @notice Book `amount` of `token` (address(0) = ETH sent as msg.value) to a seat. Anyone may pay.
    function credit(uint256 tokenId, address token, uint256 amount) external payable nonReentrant {
        if (_seats[tokenId].owner == address(0)) revert SeatNotDeposited(tokenId);
        if (amount == 0) revert ZeroAmount();
        uint256 received;
        if (token == address(0)) {
            if (msg.value != amount) revert WrongValue(amount, msg.value);
            received = amount;
        } else {
            if (msg.value != 0) revert WrongValue(0, msg.value);
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            received = IERC20(token).balanceOf(address(this)) - before;
            if (received == 0) revert ZeroAmount();
        }
        _book(tokenId, token, received);
        emit Credited(tokenId, token, msg.sender, received);
    }

    /// @notice Call a reward distributor on behalf of a seat you deposited and book what arrives in `tokens`.
    /// @dev `target` may not be the seat NFT, the bond token, this contract, or any token that has booked
    ///      balances. The call carries no value. Afterwards this contract must still hold the seat and the balance
    ///      of every listed token must not have decreased. ETH is always measured, whether or not `address(0)` is
    ///      listed, because `receive` only opens during this call and nothing that arrives may stay unattributed.
    function claim(uint256 tokenId, address target, bytes calldata data, address[] calldata tokens)
        external
        nonReentrant
    {
        _onlyOwner(tokenId);
        if (
            target == address(seatNFT) || target == address(bondToken) || target == address(this)
                || totalCredited[target] != 0
        ) revert ForbiddenTarget(target);

        uint256 ethBefore = address(this).balance;
        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            before[i] = _balanceOf(tokens[i]);
        }

        _claimActive = true;
        (bool ok, bytes memory reason) = target.call(data);
        _claimActive = false;
        if (!ok) revert ClaimFailed(reason);
        emit Claimed(tokenId, target, data);

        if (seatNFT.ownerOf(tokenId) != address(this)) revert NftNotHeld(tokenId);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) continue;
            uint256 afterwards = _balanceOf(tokens[i]);
            if (afterwards < before[i]) revert BookedBalanceDecreased(tokens[i], before[i], afterwards);
            uint256 gained = afterwards - before[i];
            if (gained != 0) _book(tokenId, tokens[i], gained);
        }
        uint256 ethGained = address(this).balance - ethBefore;
        if (ethGained != 0) _book(tokenId, address(0), ethGained);
    }

    /// @notice Pay out a seat's booked balance of `token` to its owner and operator by `ownerBps`.
    ///         A vacant seat pays everything to the owner. Anyone may call.
    function sweep(uint256 tokenId, address token) external nonReentrant {
        Seat storage s = _seats[tokenId];
        address owner = s.owner;
        if (owner == address(0)) revert SeatNotDeposited(tokenId);
        uint256 amount = _credited[tokenId][token];
        if (amount == 0) revert ZeroAmount();

        _credited[tokenId][token] = 0;
        totalCredited[token] -= amount;

        address operator = s.operator;
        uint256 ownerAmount = operator == address(0) ? amount : (amount * s.ownerBps) / BPS;
        uint256 operatorAmount = amount - ownerAmount;
        emit Swept(tokenId, token, owner, ownerAmount, operator, operatorAmount);

        _pay(token, owner, ownerAmount);
        _pay(token, operator, operatorAmount);
    }

    /// @notice Collect a bond that could not be pushed to you when your seat was cleared.
    function redeemBond() external nonReentrant {
        uint256 amount = bondOwed[msg.sender];
        if (amount == 0) revert NothingOwed(msg.sender);
        bondOwed[msg.sender] = 0;
        emit BondRedeemed(msg.sender, amount);
        bondToken.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-1271
    // ---------------------------------------------------------------------------------------------

    /// @notice ERC-1271 check used by the network when pairing a device to a leased seat.
    /// @param hash The EIP-712 digest of the WorkerAuthorization under the network domain.
    /// @param signature `abi.encode(deviceKey, wallet, tokenId, nonce, expiresAt, relayOrigin, operatorSignature)`.
    /// @return `0x1626ba7e` when the encoded authorization hashes to `hash`, names this contract as wallet, its seat
    ///         has an operator, that operator signed `hash`, and the authorization has not expired. `0xffffffff`
    ///         otherwise, including for malformed bytes.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        WorkerAuthorization memory auth;
        bytes memory operatorSignature;
        try this.decodeAuthorization(signature) returns (WorkerAuthorization memory a, bytes memory sig) {
            auth = a;
            operatorSignature = sig;
        } catch {
            return FAIL_VALUE;
        }
        if (auth.wallet != address(this)) return FAIL_VALUE;
        if (hashWorkerAuthorization(auth) != hash) return FAIL_VALUE;
        if (auth.expiresAt <= block.timestamp) return FAIL_VALUE;
        address operator = _seats[auth.tokenId].operator;
        if (operator == address(0)) return FAIL_VALUE;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, operatorSignature);
        if (err != ECDSA.RecoverError.NoError || recovered != operator) return FAIL_VALUE;
        return MAGIC_VALUE;
    }

    /// @notice Split an ERC-1271 signature blob into its authorization and the operator's signature.
    /// @dev External so `isValidSignature` can catch decoding failures instead of reverting.
    function decodeAuthorization(bytes calldata signature)
        external
        pure
        returns (WorkerAuthorization memory auth, bytes memory operatorSignature)
    {
        (
            auth.deviceKey, auth.wallet, auth.tokenId, auth.nonce, auth.expiresAt, auth.relayOrigin, operatorSignature
        ) = abi.decode(signature, (bytes32, address, uint256, bytes32, uint64, string, bytes));
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Full state of a seat.
    function seat(uint256 tokenId) external view returns (Seat memory) {
        return _seats[tokenId];
    }

    /// @notice Booked, not yet swept, balance of `token` for a seat.
    function credited(uint256 tokenId, address token) external view returns (uint256) {
        return _credited[tokenId][token];
    }

    /// @notice Whether an oracle request id has already been consumed by `cutByOracle`.
    function usedRequest(bytes32 requestId) external view returns (bool) {
        return _usedRequests[requestId];
    }

    /// @notice The network's WorkerAuthorization domain: name, version, chain id, verifying contract (the seat NFT).
    function workerDomain()
        external
        view
        returns (string memory name, string memory version, uint256 chainId, address verifyingContract)
    {
        return (_workerName, _workerVersion, block.chainid, address(seatNFT));
    }

    /// @notice EIP-712 domain separator of the network's WorkerAuthorization domain.
    function workerDomainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, _workerNameHash, _workerVersionHash, block.chainid, address(seatNFT))
        );
    }

    /// @notice EIP-712 domain separator of this contract's "IdentityMD Oracle" / "1" domain.
    function oracleDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice EIP-712 digest of a WorkerAuthorization under the network domain.
    function hashWorkerAuthorization(WorkerAuthorization memory auth) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                WORKER_AUTHORIZATION_TYPEHASH,
                auth.deviceKey,
                auth.wallet,
                auth.tokenId,
                auth.nonce,
                auth.expiresAt,
                keccak256(bytes(auth.relayOrigin))
            )
        );
        return MessageHashUtils.toTypedDataHash(workerDomainSeparator(), structHash);
    }

    /// @notice EIP-712 digest of an OracleAttestation under this contract's oracle domain.
    function hashOracleAttestation(OracleAttestation calldata attestation) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORACLE_ATTESTATION_TYPEHASH,
                attestation.requestId,
                attestation.chainId,
                attestation.questionHash,
                attestation.answerType,
                keccak256(attestation.answer),
                attestation.figure,
                attestation.fromBlock,
                attestation.toBlock,
                attestation.blockHash,
                attestation.panelJobId,
                attestation.issuedAt,
                attestation.expiresAt
            )
        );
        return _hashTypedDataV4(structHash);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-721 receiver
    // ---------------------------------------------------------------------------------------------

    /// @dev Accepts only the seat NFT, and only the token whose deposit is in flight.
    function onERC721Received(address, address, uint256 tokenId, bytes memory) public view override returns (bytes4) {
        if (!_depositActive || msg.sender != address(seatNFT) || tokenId != _depositing) {
            revert UnexpectedToken(msg.sender, tokenId);
        }
        return this.onERC721Received.selector;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _onlyOwner(uint256 tokenId) private view returns (Seat storage s) {
        s = _seats[tokenId];
        if (s.owner == address(0)) revert SeatNotDeposited(tokenId);
        if (s.owner != msg.sender) revert NotSeatOwner(tokenId, msg.sender);
    }

    function _setTerms(
        Seat storage s,
        uint256 tokenId,
        uint16 ownerBps,
        Mode mode,
        address allowedOperator,
        uint256 bondAmount,
        address oracleSigner,
        bytes32 questionHash,
        string calldata listing
    ) private {
        if (ownerBps > BPS) revert InvalidBps(ownerBps);
        if (bytes(listing).length > MAX_LISTING_BYTES) revert ListingTooLong(bytes(listing).length);
        s.ownerBps = ownerBps;
        s.mode = mode;
        s.allowedOperator = allowedOperator;
        s.bondAmount = bondAmount;
        s.oracleSigner = oracleSigner;
        s.questionHash = questionHash;
        s.listing = listing;
        emit TermsSet(tokenId, ownerBps, mode, allowedOperator, bondAmount, oracleSigner, questionHash, listing);
    }

    function _clearOperator(Seat storage s) private returns (uint256 held) {
        held = s.bondHeld;
        s.operator = address(0);
        s.bondHeld = 0;
    }

    function _book(uint256 tokenId, address token, uint256 amount) private {
        _credited[tokenId][token] += amount;
        totalCredited[token] += amount;
        emit Booked(tokenId, token, amount);
    }

    function _balanceOf(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @dev Pushes a bond. If the bond token refuses the transfer (for example a blocklisted recipient) the
    ///      amount is escrowed for `redeemBond` so the seat is never stuck occupied.
    function _payBond(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = address(bondToken).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        bool success = ok
            && (ret.length == 0
                    ? address(bondToken).code.length != 0
                    : (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
        if (!success) {
            bondOwed[to] += amount;
            emit BondEscrowed(to, amount);
        }
    }

    function _pay(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
