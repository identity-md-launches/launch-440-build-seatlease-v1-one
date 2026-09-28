// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SeatLease} from "../src/SeatLease.sol";
import {MockSeatNFT} from "../src/mocks/MockSeatNFT.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Deploy SeatLease
/// @notice Environment-driven deployment usable unchanged from Anvil to mainnet.
///
/// Environment variables read by `run()`:
///   PRIVATE_KEY            deployer key (or pass --private-key / --account on the CLI and leave unset)
///   SEAT_NFT               seat NFT address; when unset and DEPLOY_MOCKS=true a MockSeatNFT is deployed
///   BOND_TOKEN             bond ERC-20 address; when unset and DEPLOY_MOCKS=true a MockERC20 is deployed
///   DEPLOY_MOCKS           "true" to deploy mocks for missing addresses (never on mainnet)
///   WORKER_DOMAIN_NAME     WorkerAuthorization EIP-712 domain name, default "IdentityMD Worker"
///   WORKER_DOMAIN_VERSION  WorkerAuthorization EIP-712 domain version, default "2"
///
/// The RPC endpoint is given on the command line: `forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast`.
contract Deploy is Script {
    struct Config {
        address seatNFT;
        address bondToken;
        bool deployMocks;
        string workerDomainName;
        string workerDomainVersion;
    }

    struct Deployment {
        address seatNFT;
        address bondToken;
        address seatLease;
    }

    function run() external returns (Deployment memory d) {
        Config memory cfg = Config({
            seatNFT: vm.envOr("SEAT_NFT", address(0)),
            bondToken: vm.envOr("BOND_TOKEN", address(0)),
            deployMocks: vm.envOr("DEPLOY_MOCKS", false),
            workerDomainName: vm.envOr("WORKER_DOMAIN_NAME", string("IdentityMD Worker")),
            workerDomainVersion: vm.envOr("WORKER_DOMAIN_VERSION", string("2"))
        });
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        d = deploy(cfg);
        vm.stopBroadcast();
        console.log("SEAT_NFT   ", d.seatNFT);
        console.log("BOND_TOKEN ", d.bondToken);
        console.log("SEAT_LEASE ", d.seatLease);
    }

    /// @notice Deploys according to `cfg`. Called by `run()` and directly by tests.
    function deploy(Config memory cfg) public returns (Deployment memory d) {
        require(block.chainid != 1 || !cfg.deployMocks, "mocks are never deployed on mainnet");
        d.seatNFT = cfg.seatNFT;
        d.bondToken = cfg.bondToken;
        if (d.seatNFT == address(0)) {
            require(cfg.deployMocks, "SEAT_NFT required");
            d.seatNFT = address(new MockSeatNFT());
        }
        if (d.bondToken == address(0)) {
            require(cfg.deployMocks, "BOND_TOKEN required");
            d.bondToken = address(new MockERC20("Mock Bond", "BOND"));
        }
        d.seatLease = address(new SeatLease(d.seatNFT, d.bondToken, cfg.workerDomainName, cfg.workerDomainVersion));
    }
}
