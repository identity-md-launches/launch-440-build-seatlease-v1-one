// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SeatHolder} from "./SeatHolder.sol";

/// @title SeatLease v1
/// @notice A registry that lets the owner of an IdentityMD seat (ERC-721) let an operator run the seat while both
///         share the rewards the network pays to the seat's wallet.
/// @dev No upgradeability, no global admin, no pause, no selfdestruct. Every seat is administered by the address
///      that deposited it. Each deposited seat is held by its own `SeatHolder`, a wallet the registry controls, so
///      the rewards a distributor pays to that wallet belong to that seat alone. The holder answers ERC-1271
///      `isValidSignature` for the seat's current operator by deferring to this contract, so the network can pair a
///      device to a leased seat. Rewards booked to a seat are split between owner and operator at booking time.
contract SeatLease is IERC1271, EIP712, ReentrancyGuard {
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
        /// @dev `take` is refused before this timestamp. Set to now + TERMS_DELAY by `setTerms` and `withdraw`.
        uint64 termsActiveAt;
        /// @dev When and at which block the current operator took the seat; zero while vacant.
        uint64 takenAt;
        uint64 takenBlock;
    }

    /// @notice The network's device pairing message. `wallet` must be the seat's holder.
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
    /// @notice Maximum number of ERC-20 rewards collected at each operator change. ETH is always collected.
    uint256 public constant MAX_REWARD_TOKENS = 16;
    /// @notice `answerType` value the oracle uses for boolean answers.
    uint8 public constant ANSWER_TYPE_BOOL = 1;
    /// @notice How long after `setTerms` (or `withdraw`) a seat's terms must stand before anyone can take it.
    ///         An operator whose `take` lands within this window of reading active terms is seated under exactly
    ///         those terms or not at all.
    uint64 public constant TERMS_DELAY = 1 hours;
    /// @notice Gas forwarded when `sweep` pushes ETH. A recipient that needs more, or that reverts, keeps its
    ///         share booked and collects it later with `sweepFor`.
    uint256 public constant SWEEP_ETH_GAS = 100_000;
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

    /// @notice The seat NFT this registry leases.
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
    /// @dev The wallet of each seat, created on first deposit and reused for every later deposit of the token id.
    mapping(uint256 tokenId => SeatHolder) private _holders;
    /// @dev Owner-declared, bounded list; immutable during a tenure so outgoing rewards cannot be skipped.
    mapping(uint256 tokenId => address[]) private _rewardTokens;
    /// @dev Unswept booked balance of a seat per token; the sum of that seat's `_shares` for the token.
    mapping(uint256 tokenId => mapping(address token => uint256 amount)) private _credited;
    /// @dev What each account is owed out of a seat's booked balance, fixed at booking time.
    mapping(uint256 tokenId => mapping(address token => mapping(address account => uint256 amount))) private _shares;
    mapping(bytes32 requestId => bool used) private _usedRequests;
    /// @notice Total amount of `token` booked to seats and not yet paid out.
    mapping(address token => uint256 amount) public totalCredited;
    /// @notice Bond that could not be pushed to `account` and waits for `redeemBond`.
    mapping(address account => uint256 amount) public bondOwed;

    /// @dev Token id whose deposit is in flight; its holder accepts the seat NFT only while this is set.
    uint256 private _depositing;
    bool private _depositActive;
    /// @dev True while a holder forwards ETH to the registry; the only window in which `receive` accepts ETH.
    bool private _collecting;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event HolderCreated(uint256 indexed tokenId, address indexed holder);
    event SeatDeposited(uint256 indexed tokenId, address indexed owner);
    event TermsSet(
        uint256 indexed tokenId,
        uint16 ownerBps,
        Mode mode,
        address allowedOperator,
        uint256 bondAmount,
        address oracleSigner,
        bytes32 questionHash,
        string listing,
        uint64 activeAt
    );
    event SeatTaken(uint256 indexed tokenId, address indexed operator, uint256 bondHeld);
    event RewardTokensSet(uint256 indexed tokenId, address[] tokens, uint64 activeAt);
    event SeatQuit(uint256 indexed tokenId, address indexed operator, uint256 bondReturned);
    event SeatCut(uint256 indexed tokenId, address indexed operator, uint256 bondReturned);
    event SeatCutByOracle(
        uint256 indexed tokenId, address indexed operator, bytes32 indexed requestId, uint256 bondForfeited
    );
    event SeatWithdrawn(uint256 indexed tokenId, address indexed owner);
    event Credited(uint256 indexed tokenId, address indexed token, address indexed from, uint256 amount);
    event Claimed(uint256 indexed tokenId, address indexed target, bytes data);
    event Skimmed(uint256 indexed tokenId, address indexed token, uint256 amount);
    event Booked(uint256 indexed tokenId, address indexed token, uint256 amount);
    event ShareAccrued(uint256 indexed tokenId, address indexed token, address indexed account, uint256 amount);
    event Swept(
        uint256 indexed tokenId,
        address indexed token,
        address owner,
        uint256 ownerAmount,
        address operator,
        uint256 operatorAmount
    );
    event SharePaid(uint256 indexed tokenId, address indexed token, address indexed account, uint256 amount);
    event ShareRetained(uint256 indexed tokenId, address indexed token, address indexed account, uint256 amount);
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
    error TermsNotActive(uint256 tokenId, uint64 activeAt);
    error InvalidBps(uint16 ownerBps);
    error ListingTooLong(uint256 length);
    error TooManyRewardTokens(uint256 length);
    error DuplicateRewardToken(address token);
    error NftNotReceived(uint256 tokenId);
    error NftNotHeld(uint256 tokenId);
    error NoOracle(uint256 tokenId);
    error OracleChainMismatch(uint256 expected, uint256 actual);
    error OracleQuestionMismatch(bytes32 expected, bytes32 actual);
    error OracleAnswerNotBool(uint8 answerType);
    error OracleAnswerNotTrue();
    error OracleAttestationExpired(uint64 expiresAt);
    error OracleAttestationPredatesTenure(uint64 issuedAt, uint64 takenAt);
    error OracleWindowPredatesTenure(uint64 fromBlock, uint64 takenBlock);
    error OracleRequestUsed(bytes32 requestId);
    error OracleSignerMismatch(address expected, address actual);
    error WrongValue(uint256 expected, uint256 actual);
    error ZeroAmount();
    error ForbiddenTarget(address target);
    error ForbiddenToken(address token);
    error ClaimFailed(bytes reason);
    error HolderBalanceDecreased(address token, uint256 before, uint256 afterwards);
    error NothingOwed(address account);
    error DirectEthNotAccepted();
    error MalformedAuthorization();

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

    /// @dev Plain ETH is refused so it can never sit unattributed. Use `credit(tokenId, address(0), amount)`, or
    ///      pay the seat's holder and let anyone `skim` it. The only exception is ETH a holder forwards while the
    ///      registry collects it, every wei of which is booked to that holder's seat.
    receive() external payable {
        if (!_collecting) revert DirectEthNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Seat lifecycle
    // ---------------------------------------------------------------------------------------------

    /// @notice Deposit a seat you own and record its lease terms. The seat moves into its own holder, which is
    ///         created on the first deposit of the token id and reused afterwards.
    /// @dev The oracle attestation carries no tokenId, so an attestation for `questionHash` is valid for every seat
    ///      that shares that hash and `oracleSigner`. Give each seat its own question (for example, include the
    ///      tokenId in the question text the oracle answers) so an attestation can only cut the seat it was issued for.
    ///      Terms recorded here are live at once unless the token id was withdrawn less than `TERMS_DELAY` ago.
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

        SeatHolder holder = _holders[tokenId];
        if (address(holder) == address(0)) {
            holder = new SeatHolder{salt: bytes32(tokenId)}(seatNFT, tokenId);
            _holders[tokenId] = holder;
            emit HolderCreated(tokenId, address(holder));
        }

        s.owner = msg.sender;
        emit SeatDeposited(tokenId, msg.sender);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 activeAt = s.termsActiveAt > block.timestamp ? s.termsActiveAt : uint64(block.timestamp);
        _setTerms(
            s, tokenId, ownerBps, mode, allowedOperator, bondAmount, oracleSigner, questionHash, listing, activeAt
        );

        _depositing = tokenId;
        _depositActive = true;
        seatNFT.safeTransferFrom(msg.sender, address(holder), tokenId);
        _depositActive = false;
        if (seatNFT.ownerOf(tokenId) != address(holder)) revert NftNotReceived(tokenId);
    }

    /// @notice Change the terms of a vacant seat you deposited. The new terms can be taken after `TERMS_DELAY`, so a
    ///         change can never land between an operator reading the terms and its `take` executing.
    function setTerms(
        uint256 tokenId,
        uint16 ownerBps,
        Mode mode,
        address allowedOperator,
        uint256 bondAmount,
        address oracleSigner,
        bytes32 questionHash,
        string calldata listing
    ) external nonReentrant {
        Seat storage s = _onlyOwner(tokenId);
        if (s.operator != address(0)) revert SeatNotVacant(tokenId);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 activeAt = uint64(block.timestamp + TERMS_DELAY);
        _setTerms(
            s, tokenId, ownerBps, mode, allowedOperator, bondAmount, oracleSigner, questionHash, listing, activeAt
        );
    }

    /// @notice Declare the ERC-20 rewards to settle before every operator change. Owner only, vacant only.
    /// @dev ETH is implicit. Tokens must be transferable ERC-20s; their balance/transfer calls must remain usable.
    ///      Changing the list delays `take` just like changing other terms. Undeclared tokens can still be skimmed,
    ///      but have no settlement guarantee across operator changes. No caller can grow this list with dust.
    function setRewardTokens(uint256 tokenId, address[] calldata tokens) external nonReentrant {
        Seat storage s = _onlyOwner(tokenId);
        if (s.operator != address(0)) revert SeatNotVacant(tokenId);
        if (tokens.length > MAX_REWARD_TOKENS) revert TooManyRewardTokens(tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (token == address(seatNFT) || token.code.length == 0 || !_answersBalanceOf(token)) {
                revert ForbiddenToken(token);
            }
            if (_listedBefore(tokens, i)) revert DuplicateRewardToken(token);
        }
        _rewardTokens[tokenId] = tokens;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.termsActiveAt = uint64(block.timestamp + TERMS_DELAY);
        emit RewardTokensSet(tokenId, tokens, s.termsActiveAt);
    }

    /// @notice Become the operator of a vacant seat whose terms are active. Open seats pull `bondAmount` of the bond
    ///         token from the caller.
    function take(uint256 tokenId) external nonReentrant {
        Seat storage s = _seats[tokenId];
        if (s.owner == address(0)) revert SeatNotDeposited(tokenId);
        if (s.operator != address(0)) revert SeatNotVacant(tokenId);
        if (block.timestamp < s.termsActiveAt) revert TermsNotActive(tokenId, s.termsActiveAt);

        uint256 held = 0;
        if (s.mode == Mode.Permissioned) {
            if (msg.sender != s.allowedOperator) revert NotAllowedOperator(tokenId, msg.sender);
        } else if (s.bondAmount != 0) {
            uint256 before = bondToken.balanceOf(address(this));
            bondToken.safeTransferFrom(msg.sender, address(this), s.bondAmount);
            held = bondToken.balanceOf(address(this)) - before;
        }

        _settleHolder(tokenId);
        s.operator = msg.sender;
        s.bondHeld = held;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.takenAt = uint64(block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.takenBlock = uint64(block.number);
        emit SeatTaken(tokenId, msg.sender, held);
    }

    /// @notice Leave a seat you operate. Your bond is returned. Shares already booked to you stay yours.
    function quit(uint256 tokenId) external nonReentrant {
        Seat storage s = _seats[tokenId];
        if (msg.sender != s.operator) revert NotOperator(tokenId, msg.sender);
        _settleHolder(tokenId);
        uint256 held = _clearOperator(s);
        emit SeatQuit(tokenId, msg.sender, held);
        _payBond(msg.sender, held);
    }

    /// @notice Remove the operator of a seat you deposited. The operator's bond is returned to them and the shares
    ///         already booked to them stay theirs.
    function cut(uint256 tokenId) external nonReentrant {
        Seat storage s = _onlyOwner(tokenId);
        address operator = s.operator;
        if (operator == address(0)) revert SeatVacant(tokenId);
        _settleHolder(tokenId);
        uint256 held = _clearOperator(s);
        emit SeatCut(tokenId, operator, held);
        _payBond(operator, held);
    }

    /// @notice Remove the operator of a seat on the strength of a signed oracle attestation that answers the
    ///         seat's question with `true`. The operator's bond is forfeited to the seat owner.
    /// @dev The attestation must have been issued, and its observation window must start, no earlier than the
    ///      current operator took the seat, so an attestation about a previous operator can never cut this one.
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
        if (attestation.issuedAt < s.takenAt) revert OracleAttestationPredatesTenure(attestation.issuedAt, s.takenAt);
        if (attestation.fromBlock < s.takenBlock) {
            revert OracleWindowPredatesTenure(attestation.fromBlock, s.takenBlock);
        }
        if (_usedRequests[attestation.requestId]) revert OracleRequestUsed(attestation.requestId);
        address recovered = ECDSA.recover(hashOracleAttestation(attestation), signature);
        if (recovered != signer) revert OracleSignerMismatch(signer, recovered);

        _usedRequests[attestation.requestId] = true;
        _settleHolder(tokenId);
        uint256 held = _clearOperator(s);
        emit SeatCutByOracle(tokenId, operator, attestation.requestId, held);
        _payBond(s.owner, held);
    }

    /// @notice Take back a vacant seat you deposited. Booked shares stay with the accounts they were booked to and
    ///         can still be collected with `sweepFor`. The token id cannot be taken again until `TERMS_DELAY` after
    ///         this call, so a withdraw-and-redeposit cannot swap terms under a pending `take`.
    function withdraw(uint256 tokenId) external nonReentrant {
        Seat storage s = _onlyOwner(tokenId);
        if (s.operator != address(0)) revert SeatNotVacant(tokenId);
        SeatHolder holder = _holders[tokenId];
        _settleHolder(tokenId);
        delete _rewardTokens[tokenId];
        delete _seats[tokenId];
        // forge-lint: disable-next-line(unsafe-typecast)
        _seats[tokenId].termsActiveAt = uint64(block.timestamp + TERMS_DELAY);
        emit SeatWithdrawn(tokenId, msg.sender);
        holder.releaseNft(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Rewards
    // ---------------------------------------------------------------------------------------------

    /// @notice Book `amount` of `token` (address(0) = ETH sent as msg.value) to a seat. Anyone may pay.
    /// @dev The seat NFT is refused as `token`: its `transferFrom` shares the ERC-20 selector and would pull a seat
    ///      into the registry that could never be swept out again.
    function credit(uint256 tokenId, address token, uint256 amount) external payable nonReentrant {
        if (_seats[tokenId].owner == address(0)) revert SeatNotDeposited(tokenId);
        if (amount == 0) revert ZeroAmount();
        if (token == address(seatNFT)) revert ForbiddenToken(token);
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
        _book(tokenId, token, received, _seats[tokenId].operator);
        emit Credited(tokenId, token, msg.sender, received);
    }

    /// @notice Call a reward distributor as the wallet of a seat you deposited and book what arrives in `tokens`.
    /// @dev The seat's holder makes the call, so the target can reach nothing but that seat's own wallet. `target`
    ///      may not be the seat NFT, the bond token, this contract, the holder, an address without code, a token that
    ///      has booked balances, or any contract that answers `balanceOf(address(this))`: the holder is `msg.sender`
    ///      of the call, so it must never call a token it could hold (an `approve` would outlive the call and let the
    ///      owner drain rewards before they are booked). `tokens` may not name the seat NFT; a token listed more
    ///      than once is collected once. The call carries no value. Afterwards the holder must still own the seat
    ///      and its balance of every listed token must not have decreased. The holder's whole balance of each
    ///      listed token, and all of its ETH whether or not `address(0)` is listed, is then moved here and booked.
    ///      Anything the holder receives in a token that was not listed can be booked later with `skim`.
    function claim(uint256 tokenId, address target, bytes calldata data, address[] calldata tokens)
        external
        nonReentrant
    {
        _onlyOwner(tokenId);
        SeatHolder holder = _holders[tokenId];
        if (
            target == address(seatNFT) || target == address(bondToken) || target == address(this)
                || target == address(holder) || target.code.length == 0 || totalCredited[target] != 0
                || _answersBalanceOf(target)
        ) revert ForbiddenTarget(target);

        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(seatNFT)) revert ForbiddenToken(tokens[i]);
            before[i] = _balanceOf(address(holder), tokens[i]);
        }

        (bool ok, bytes memory reason) = holder.execute(target, data);
        if (!ok) revert ClaimFailed(reason);
        emit Claimed(tokenId, target, data);

        if (seatNFT.ownerOf(tokenId) != address(holder)) revert NftNotHeld(tokenId);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0) || _listedBefore(tokens, i)) continue;
            uint256 afterwards = _balanceOf(address(holder), tokens[i]);
            if (afterwards < before[i]) revert HolderBalanceDecreased(tokens[i], before[i], afterwards);
            _collect(tokenId, holder, tokens[i]);
        }
        _collect(tokenId, holder, address(0));
    }

    /// @notice Book whatever a seat's holder holds of `token` (address(0) = ETH). Anyone may call. This is how
    ///         rewards that reach the wallet outside `claim` (a distributor claimed by a third party, a token that
    ///         was not listed, ETH sent to the holder) are attributed to the seat.
    function skim(uint256 tokenId, address token) external nonReentrant {
        if (_seats[tokenId].owner == address(0)) revert SeatNotDeposited(tokenId);
        if (token == address(seatNFT)) revert ForbiddenToken(token);
        uint256 received = _collect(tokenId, _holders[tokenId], token);
        if (received == 0) revert ZeroAmount();
        emit Skimmed(tokenId, token, received);
    }

    /// @notice Pay out what a seat's owner and current operator are owed in `token`. Anyone may call. Shares were
    ///         split by `ownerBps` when they were booked (all to the owner while vacant), so who holds the seat now
    ///         changes nothing about balances booked earlier. A share whose push fails stays booked to its account.
    function sweep(uint256 tokenId, address token) external nonReentrant {
        Seat storage s = _seats[tokenId];
        address owner = s.owner;
        if (owner == address(0)) revert SeatNotDeposited(tokenId);
        address operator = s.operator;
        uint256 ownerAmount = _shares[tokenId][token][owner];
        uint256 operatorAmount = operator == address(0) || operator == owner ? 0 : _shares[tokenId][token][operator];
        if (ownerAmount + operatorAmount == 0) revert ZeroAmount();

        emit Swept(tokenId, token, owner, ownerAmount, operator, operatorAmount);
        _payShare(tokenId, token, owner, ownerAmount, SWEEP_ETH_GAS);
        _payShare(tokenId, token, operator, operatorAmount, SWEEP_ETH_GAS);
    }

    /// @notice Pay `account` the share of a seat's `token` balance that was booked to it, whether or not it still
    ///         owns or operates the seat and whether or not the seat is still deposited. Anyone may call.
    /// @dev ETH forwards available gas: a heavy recipient can collect here without blocking another recipient.
    function sweepFor(uint256 tokenId, address token, address account) external nonReentrant {
        uint256 amount = _shares[tokenId][token][account];
        if (amount == 0) revert ZeroAmount();
        _payShare(tokenId, token, account, amount, gasleft());
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

    /// @notice ERC-1271 check used by the network when pairing a device to a leased seat. The seat's holder answers
    ///         the same question for the network by calling `isValidSignatureFor`.
    /// @param hash The EIP-712 digest of the WorkerAuthorization under the network domain.
    /// @param signature `abi.encode(deviceKey, wallet, tokenId, nonce, expiresAt, relayOrigin, operatorSignature)`.
    /// @return `0x1626ba7e` when the encoded authorization hashes to `hash`, names the seat's holder as wallet, the
    ///         seat has an operator, that operator signed `hash`, and the authorization has not expired.
    ///         `0xffffffff` otherwise, including for malformed bytes.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        return _isValid(hash, signature, address(0));
    }

    /// @notice Same as `isValidSignature`, additionally requiring the authorization's wallet to be `wallet`.
    ///         Holders call this with their own address so an authorization for another seat never validates
    ///         through them.
    function isValidSignatureFor(address wallet, bytes32 hash, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        return _isValid(hash, signature, wallet);
    }

    /// @notice Split an ERC-1271 signature blob into its authorization and the operator's signature.
    /// @dev External so `isValidSignature` can catch decoding failures instead of reverting. Only the canonical
    ///      `abi.encode` of the fields is accepted: a blob with trailing or otherwise non-canonical bytes reverts,
    ///      so every accepted authorization has exactly one byte encoding.
    function decodeAuthorization(bytes calldata signature)
        external
        pure
        returns (WorkerAuthorization memory auth, bytes memory operatorSignature)
    {
        (
            auth.deviceKey, auth.wallet, auth.tokenId, auth.nonce, auth.expiresAt, auth.relayOrigin, operatorSignature
        ) = abi.decode(signature, (bytes32, address, uint256, bytes32, uint64, string, bytes));
        bytes memory canonical = abi.encode(
            auth.deviceKey, auth.wallet, auth.tokenId, auth.nonce, auth.expiresAt, auth.relayOrigin, operatorSignature
        );
        if (keccak256(canonical) != keccak256(signature)) revert MalformedAuthorization();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Full state of a seat.
    function seat(uint256 tokenId) external view returns (Seat memory) {
        return _seats[tokenId];
    }

    /// @notice The wallet that holds a seat and receives its rewards; zero until the token id is first deposited.
    function holderOf(uint256 tokenId) external view returns (address) {
        return address(_holders[tokenId]);
    }

    /// @notice ERC-20 rewards settled on operator changes. ETH is always settled separately.
    function rewardTokens(uint256 tokenId) external view returns (address[] memory) {
        return _rewardTokens[tokenId];
    }

    /// @notice Booked, not yet swept, balance of `token` for a seat: the sum of every account's share.
    function credited(uint256 tokenId, address token) external view returns (uint256) {
        return _credited[tokenId][token];
    }

    /// @notice What `account` is owed out of a seat's booked balance of `token`.
    function share(uint256 tokenId, address token, address account) external view returns (uint256) {
        return _shares[tokenId][token][account];
    }

    /// @notice Whether an oracle request id has already been consumed by `cutByOracle`.
    function usedRequest(bytes32 requestId) external view returns (bool) {
        return _usedRequests[requestId];
    }

    /// @notice True while `deposit` is moving `tokenId` into its holder; the holder accepts the NFT only then.
    function depositInFlight(uint256 tokenId) external view returns (bool) {
        return _depositActive && _depositing == tokenId;
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
        string calldata listing,
        uint64 activeAt
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
        s.termsActiveAt = activeAt;
        emit TermsSet(
            tokenId, ownerBps, mode, allowedOperator, bondAmount, oracleSigner, questionHash, listing, activeAt
        );
    }

    function _clearOperator(Seat storage s) private returns (uint256 held) {
        held = s.bondHeld;
        s.operator = address(0);
        s.bondHeld = 0;
        s.takenAt = 0;
        s.takenBlock = 0;
    }

    /// @dev Books a final split. A zero `operator` assigns everything to the owner (vacancy or holder warm-up).
    function _book(uint256 tokenId, address token, uint256 amount, address operator) private {
        Seat storage s = _seats[tokenId];
        uint256 ownerPart = operator == address(0) ? amount : (amount * s.ownerBps) / BPS;
        uint256 operatorPart = amount - ownerPart;
        _credited[tokenId][token] += amount;
        totalCredited[token] += amount;
        emit Booked(tokenId, token, amount);
        if (ownerPart != 0) {
            _shares[tokenId][token][s.owner] += ownerPart;
            emit ShareAccrued(tokenId, token, s.owner, ownerPart);
        }
        if (operatorPart != 0) {
            _shares[tokenId][token][operator] += operatorPart;
            emit ShareAccrued(tokenId, token, operator, operatorPart);
        }
    }

    /// @dev Settle under the outgoing tenure, before changing operator or clearing the seat's owner.
    function _settleHolder(uint256 tokenId) private {
        SeatHolder holder = _holders[tokenId];
        _collect(tokenId, holder, address(0));
        address[] storage tokens = _rewardTokens[tokenId];
        for (uint256 i; i < tokens.length; ++i) {
            _collect(tokenId, holder, tokens[i]);
        }
    }

    /// @dev Moves the holder's whole balance of `token` to the registry and books what arrives. During the first
    ///      TERMS_DELAY of a tenure, holder collections belong entirely to the owner. This prevents an atomic
    ///      take/claim-for-holder/skim/quit from sharing rewards that were already claimable before the take.
    function _collect(uint256 tokenId, SeatHolder holder, address token) private returns (uint256 received) {
        uint256 amount = _balanceOf(address(holder), token);
        if (amount == 0) return 0;
        uint256 before = _balanceOf(address(this), token);
        // The balance is re-read after the holder's transfer on purpose: only what actually arrived is booked
        // (fee-on-transfer tokens), and every caller of `_collect` is `nonReentrant`.
        if (token == address(0)) {
            _collecting = true;
            // forge-lint: disable-next-line(reentrancy-balance)
            holder.release(token, amount);
            _collecting = false;
        } else {
            // forge-lint: disable-next-line(reentrancy-balance)
            holder.release(token, amount);
        }
        received = _balanceOf(address(this), token) - before;
        if (received != 0) {
            Seat storage s = _seats[tokenId];
            address operator = block.timestamp < uint256(s.takenAt) + TERMS_DELAY ? address(0) : s.operator;
            _book(tokenId, token, received, operator);
        }
    }

    /// @dev Pays `account` its share; on a failed push the share stays booked so nobody else's payout is blocked.
    function _payShare(uint256 tokenId, address token, address account, uint256 amount, uint256 ethGas) private {
        if (amount == 0) return;
        _shares[tokenId][token][account] = 0;
        _credited[tokenId][token] -= amount;
        totalCredited[token] -= amount;
        if (_tryPay(token, account, amount, ethGas)) {
            emit SharePaid(tokenId, token, account, amount);
        } else {
            _shares[tokenId][token][account] = amount;
            _credited[tokenId][token] += amount;
            totalCredited[token] += amount;
            emit ShareRetained(tokenId, token, account, amount);
        }
    }

    function _balanceOf(address account, address token) private view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    /// @dev True when `tokens[i]` already appears at a lower index, so a repeated entry is collected only once.
    function _listedBefore(address[] calldata tokens, uint256 i) private pure returns (bool) {
        for (uint256 j; j < i; ++j) {
            if (tokens[j] == tokens[i]) return true;
        }
        return false;
    }

    /// @dev True when `target` answers `balanceOf(address(this))` with a word, i.e. it is a token whose balance a
    ///      holder could hold. Such a contract is never a valid `claim` target.
    function _answersBalanceOf(address target) private view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && ret.length >= 32;
    }

    /// @dev Pushes a bond. If the bond token refuses the transfer (for example a blocklisted recipient) the
    ///      amount is escrowed for `redeemBond` so the seat is never stuck occupied.
    function _payBond(address to, uint256 amount) private {
        if (amount == 0) return;
        if (!_tryTransferToken(address(bondToken), to, amount)) {
            bondOwed[to] += amount;
            emit BondEscrowed(to, amount);
        }
    }

    /// @dev Pushes ETH with the caller's gas budget, or an ERC-20 through `_tryTransferToken`.
    ///      The ETH push copies no return data, so a recipient can neither revert the sweep nor bloat it.
    function _tryPay(address token, address to, uint256 amount, uint256 ethGas) private returns (bool ok) {
        if (token == address(0)) {
            assembly ("memory-safe") {
                ok := call(ethGas, to, amount, 0, 0, 0, 0)
            }
            return ok;
        }
        return _tryTransferToken(token, to, amount);
    }

    /// @dev ERC-20 `transfer` that reports failure instead of reverting: a revert, a `false` return or a malformed
    ///      return all count as failure; empty return data counts as success only when the token has code.
    function _tryTransferToken(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 ? token.code.length != 0 : (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
    }

    function _isValid(bytes32 hash, bytes calldata signature, address wallet) private view returns (bytes4) {
        WorkerAuthorization memory auth;
        bytes memory operatorSignature;
        try this.decodeAuthorization(signature) returns (WorkerAuthorization memory a, bytes memory sig) {
            auth = a;
            operatorSignature = sig;
        } catch {
            return FAIL_VALUE;
        }
        if (wallet != address(0) && auth.wallet != wallet) return FAIL_VALUE;
        if (auth.wallet != address(_holders[auth.tokenId])) return FAIL_VALUE;
        if (hashWorkerAuthorization(auth) != hash) return FAIL_VALUE;
        if (auth.expiresAt <= block.timestamp) return FAIL_VALUE;
        address operator = _seats[auth.tokenId].operator;
        if (operator == address(0)) return FAIL_VALUE;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, operatorSignature);
        if (err != ECDSA.RecoverError.NoError || recovered != operator) return FAIL_VALUE;
        return MAGIC_VALUE;
    }
}
