// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DclexNFTDescriptor} from "src/DclexNFTDescriptor.sol";

/// @notice Standalone deploy of the NFT position descriptor.
///
/// `baseURI` is read from the env (`NFT_BASE_URI`) so the same script
/// works across dev / staging / prod without code changes. Must end with
/// a slash — the descriptor concatenates `tokenId` directly.
contract DeployNFTDescriptor is Script {
    function run() external returns (address descriptor) {
        string memory baseURI = vm.envString("NFT_BASE_URI");
        require(bytes(baseURI).length > 0, "NFT_BASE_URI required");
        // Owner ends up as the broadcaster (admin key), matching the
        // pattern used by the other periphery deploys.
        uint256 adminKey = vm.envOr("ADMIN_PRIVATE_KEY", uint256(0));
        if (adminKey == 0) {
            adminKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        }

        vm.startBroadcast(adminKey);
        DclexNFTDescriptor d = new DclexNFTDescriptor(baseURI);
        descriptor = address(d);
        vm.stopBroadcast();

        console.log("DclexNFTDescriptor:", descriptor);
        console.log("baseURI:", baseURI);
        console.log("owner:", d.owner());
    }
}
