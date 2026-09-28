// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "SeatLease");
        assertEq(token.symbol(), "SEATL");
    }

    function test_transferMovesExactAmount() public {
        address to = makeAddr("to");
        assertTrue(token.transfer(to, 1e18));
        assertEq(token.balanceOf(to), 1e18);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - 1e18);
    }

    function test_noMintFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 10 ** 27);
    }
}
