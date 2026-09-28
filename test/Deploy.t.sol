// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {MockSeatNFT} from "../src/mocks/MockSeatNFT.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev The deploy function is exercised directly with explicit configs; `run()` only wraps it with env reads.
contract DeployTest is Test {
    Deploy internal deployer;

    function setUp() public {
        deployer = new Deploy();
    }

    function test_deploy_withMocks() public {
        Deploy.Deployment memory d = deployer.deploy(
            Deploy.Config({
                seatNFT: address(0),
                bondToken: address(0),
                deployMocks: true,
                workerDomainName: "IdentityMD Worker",
                workerDomainVersion: "2"
            })
        );
        assertTrue(d.seatNFT.code.length > 0);
        assertTrue(d.bondToken.code.length > 0);
        SeatLease lease = SeatLease(payable(d.seatLease));
        assertEq(address(lease.seatNFT()), d.seatNFT);
        assertEq(address(lease.bondToken()), d.bondToken);
        (string memory name, string memory version,,) = lease.workerDomain();
        assertEq(name, "IdentityMD Worker");
        assertEq(version, "2");
        assertEq(MockSeatNFT(d.seatNFT).symbol(), "SEAT");
        assertEq(MockERC20(d.bondToken).symbol(), "BOND");
    }

    function test_deploy_withExistingAddresses() public {
        MockSeatNFT nft = new MockSeatNFT();
        MockERC20 bond = new MockERC20("B", "B");
        Deploy.Deployment memory d = deployer.deploy(
            Deploy.Config({
                seatNFT: address(nft),
                bondToken: address(bond),
                deployMocks: false,
                workerDomainName: "IdentityMD Worker",
                workerDomainVersion: "3"
            })
        );
        assertEq(d.seatNFT, address(nft));
        assertEq(d.bondToken, address(bond));
        (, string memory version,,) = SeatLease(payable(d.seatLease)).workerDomain();
        assertEq(version, "3");
    }

    function test_deploy_mixedMocks() public {
        MockSeatNFT nft = new MockSeatNFT();
        Deploy.Deployment memory d = deployer.deploy(
            Deploy.Config({
                seatNFT: address(nft),
                bondToken: address(0),
                deployMocks: true,
                workerDomainName: "IdentityMD Worker",
                workerDomainVersion: "2"
            })
        );
        assertEq(d.seatNFT, address(nft));
        assertTrue(d.bondToken != address(0));
    }

    function test_deploy_requiresAddressesWithoutMocks() public {
        Deploy.Config memory cfg = Deploy.Config({
            seatNFT: address(0),
            bondToken: address(0),
            deployMocks: false,
            workerDomainName: "IdentityMD Worker",
            workerDomainVersion: "2"
        });
        vm.expectRevert("SEAT_NFT required");
        deployer.deploy(cfg);
        cfg.seatNFT = address(new MockSeatNFT());
        vm.expectRevert("BOND_TOKEN required");
        deployer.deploy(cfg);
    }

    function test_deploy_refusesMocksOnMainnet() public {
        vm.chainId(1);
        vm.expectRevert("mocks are never deployed on mainnet");
        deployer.deploy(
            Deploy.Config({
                seatNFT: address(0),
                bondToken: address(0),
                deployMocks: true,
                workerDomainName: "IdentityMD Worker",
                workerDomainVersion: "2"
            })
        );
    }
}
