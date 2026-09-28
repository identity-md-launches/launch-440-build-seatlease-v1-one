// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Stand-in for the IdentityMD seat NFT. Anyone can mint; used for local deployment and tests only.
contract MockSeatNFT is ERC721 {
    constructor() ERC721("Mock IdentityMD Seat", "SEAT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}
