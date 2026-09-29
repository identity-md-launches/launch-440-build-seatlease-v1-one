// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SeatLease} from "./SeatLease.sol";

/// @title SeatHolder
/// @notice The wallet of one leased seat. It owns exactly one seat NFT, is the address every reward distributor
///         pays for that seat, and answers ERC-1271 for the seat's operator by deferring to the registry.
/// @dev Deployed once per tokenId by `SeatLease.deposit` with CREATE2 (salt = tokenId) and reused across
///      deposits, so a seat's wallet address never changes. Only the registry can move anything out of it.
///      Because every seat has its own holder, whatever a distributor pays this address belongs to this seat
///      and nothing else: the registry books it with `claim` or `skim` without having to attribute it.
contract SeatHolder is IERC721Receiver, IERC1271 {
    using SafeERC20 for IERC20;

    /// @notice The registry that created this holder and administers it.
    SeatLease public immutable registry;
    /// @notice The seat NFT collection.
    IERC721 public immutable seatNFT;
    /// @notice The only token id this holder ever accepts.
    uint256 public immutable tokenId;

    error NotRegistry(address caller);
    error UnexpectedToken(address collection, uint256 tokenId);
    error EthTransferFailed(address to, uint256 amount);

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) revert NotRegistry(msg.sender);
        _;
    }

    constructor(IERC721 seatNFT_, uint256 tokenId_) {
        registry = SeatLease(payable(msg.sender));
        seatNFT = seatNFT_;
        tokenId = tokenId_;
    }

    /// @dev Any ETH that reaches the holder belongs to its seat; the registry books it with `claim` or `skim`.
    receive() external payable {}

    /// @notice Call a reward distributor as the seat's wallet. Registry only.
    function execute(address target, bytes calldata data) external onlyRegistry returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }

    /// @notice Move `amount` of `token` (address(0) = ETH) to the registry so it can be booked. Registry only.
    function release(address token, uint256 amount) external onlyRegistry {
        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert EthTransferFailed(msg.sender, amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /// @notice Return the seat NFT to `to`. Registry only. Uses `transferFrom` so a contract owner that has no
    ///         `onERC721Received` can still take its seat back.
    function releaseNft(address to) external onlyRegistry {
        seatNFT.transferFrom(address(this), to, tokenId);
    }

    /// @dev Accepts only the seat NFT, only this holder's token id, and only while the registry is depositing it.
    function onERC721Received(address, address, uint256 id, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(seatNFT) || id != tokenId || !registry.depositInFlight(tokenId)) {
            revert UnexpectedToken(msg.sender, id);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice ERC-1271: valid when the registry validates the authorization for this wallet.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        return registry.isValidSignatureFor(address(this), hash, signature);
    }
}
