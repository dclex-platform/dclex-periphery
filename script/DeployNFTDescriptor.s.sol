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
    /// Anvil/local hardhat default account #1 — usable only when the
    /// admin key isn't supplied AND the chain we're targeting is one
    /// of the known dev chains. Real environments must set
    /// `ADMIN_PRIVATE_KEY`.
    uint256 internal constant LOCAL_DEFAULT_KEY =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    function run() external returns (address descriptor) {
        string memory baseURI = vm.envString("NFT_BASE_URI");
        bytes memory b = bytes(baseURI);
        require(b.length > 0, "NFT_BASE_URI required");
        require(b[b.length - 1] == "/", "NFT_BASE_URI must end with '/'");

        uint256 adminKey = _resolveAdminKey();

        vm.startBroadcast(adminKey);
        DclexNFTDescriptor d = new DclexNFTDescriptor(baseURI);
        descriptor = address(d);
        vm.stopBroadcast();

        console.log("DclexNFTDescriptor:", descriptor);
        console.log("baseURI:", baseURI);
        console.log("owner:", d.owner());
    }

    function _resolveAdminKey() internal view returns (uint256) {
        uint256 adminKey = vm.envOr("ADMIN_PRIVATE_KEY", uint256(0));
        if (adminKey != 0) return adminKey;
        // Allow the well-known dev key only on anvil (31337) and the
        // local hardhat chain (1336). Anything else (primelta-dev=2028,
        // staging, prod, …) must set ADMIN_PRIVATE_KEY explicitly.
        require(
            block.chainid == 31337 || block.chainid == 1336,
            "ADMIN_PRIVATE_KEY required (default key is dev-only)"
        );
        return LOCAL_DEFAULT_KEY;
    }
}
