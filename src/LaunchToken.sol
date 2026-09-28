// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice Fixed-supply ERC-20 required by the IdentityMD launch harness. It is not used by SeatLease: the registry
///         creates no token, and its bond token is whatever ERC-20 the deployer names in the constructor.
/// @dev No constructor arguments, 18 decimals, exactly 1,000,000,000 tokens minted to the deployer. No mint,
///      owner, pause, blocklist, fee or upgrade path.
contract LaunchToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000e18;

    constructor() ERC20("SeatLease", "SEATL") {
        _mint(msg.sender, SUPPLY);
    }
}
