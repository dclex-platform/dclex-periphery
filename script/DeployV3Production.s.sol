// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {WDEL} from "../src/WDEL.sol";
import {DclexV3Factory} from "../src/DclexV3Factory.sol";
import {DclexPositionManager} from "../src/DclexPositionManager.sol";
import {DclexNFTDescriptor} from "../src/DclexNFTDescriptor.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";

/// @title DeployV3Production
/// @notice Deploys V3 infrastructure + DclexRouter for production
/// @dev Requires: Factory and DID already deployed (from dclex-blockchain)
///      Uses admin key for all operations (must have DEFAULT_ADMIN_ROLE on Factory)
contract DeployV3Production is Script {
    struct V3Contracts {
        address wdel;
        address v3Factory;
        address swapRouter;
        address quoter;
        address positionManager;
        address nftDescriptor;
    }

    /// @notice Deploy V3 infrastructure only (no DclexRouter — that's in DeployDclexRouterWithPools)
    /// @param did DigitalIdentity contract address (for DclexPositionManager DID gating)
    function run(address did) external returns (V3Contracts memory result) {
        uint256 adminKey = vm.envOr("ADMIN_PRIVATE_KEY", uint256(0));
        if (adminKey == 0) {
            adminKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        }

        console.log("\n=== Deploying V3 Infrastructure ===");
        console.log("DID:", did);

        vm.startBroadcast(adminKey);

        // Reuse existing WDEL when redeploying V3 infra — users have balances
        // there, losing them to a fresh contract would be disruptive. Falls
        // back to creating a new one when WDEL_ADDRESS is not set (first-time
        // deploy).
        address existingWdel = vm.envOr("WDEL_ADDRESS", address(0));
        if (existingWdel != address(0)) {
            result.wdel = existingWdel;
            console.log("WDEL (reused):", result.wdel);
        } else {
            WDEL wdel = new WDEL();
            result.wdel = address(wdel);
            console.log("WDEL (new):", result.wdel);
        }

        DclexV3Factory v3Factory = new DclexV3Factory();
        result.v3Factory = address(v3Factory);
        console.log("DclexV3Factory:", result.v3Factory);

        SwapRouter swapRouter = new SwapRouter(result.v3Factory, result.wdel);
        result.swapRouter = address(swapRouter);
        console.log("SwapRouter:", result.swapRouter);

        Quoter quoter = new Quoter(result.v3Factory, result.wdel);
        result.quoter = address(quoter);
        console.log("Quoter:", result.quoter);

        // Deploy NFT descriptor first so we can hand it to the NPM
        // constructor (the base contract stores `_tokenDescriptor` as
        // immutable). NFT_BASE_URI is required on prod-like chains —
        // without it tokenURI would revert and MetaMask / OpenSea would
        // show no metadata. On local/anvil it's optional (skipped).
        result.nftDescriptor = _deployDescriptorIfConfigured();

        DclexPositionManager npm = new DclexPositionManager(
            result.v3Factory,
            result.wdel,
            result.nftDescriptor,
            IDID(did)
        );
        result.positionManager = address(npm);
        console.log("DclexPositionManager:", result.positionManager);

        vm.stopBroadcast();

        console.log("\n=== V3 Infrastructure Deployed ===");
        console.log("Next: run DeployDclexRouterWithPools with SwapRouter and Quoter addresses");
    }

    function _deployDescriptorIfConfigured() internal returns (address) {
        string memory baseURI = vm.envOr("NFT_BASE_URI", string(""));
        bytes memory b = bytes(baseURI);
        if (b.length == 0) {
            require(
                block.chainid == 31337 || block.chainid == 1336,
                "NFT_BASE_URI required on this chain (set to e.g. https://api-dev.primedelta.io/nft/positions/)"
            );
            console.log("NFT_BASE_URI unset on local chain, skipping descriptor (tokenURI will revert)");
            return address(0);
        }
        require(b[b.length - 1] == "/", "NFT_BASE_URI must end with '/'");
        DclexNFTDescriptor descriptor = new DclexNFTDescriptor(baseURI);
        console.log("DclexNFTDescriptor:", address(descriptor));
        console.log("  baseURI:", baseURI);
        return address(descriptor);
    }
}
