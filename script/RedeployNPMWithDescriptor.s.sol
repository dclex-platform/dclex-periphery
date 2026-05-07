// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DclexPositionManager} from "src/DclexPositionManager.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";

/// @notice Redeploy ONLY the DclexPositionManager so it picks up a
///         non-zero `_tokenDescriptor`.
///
/// The base `NonfungiblePositionManager` stores `_tokenDescriptor` as
/// `immutable`, so changing it requires redeploying the manager. We keep
/// the existing V3 factory + WDEL + SwapRouter + Quoter — only positions
/// minted after this point pick up the new NPM. Existing positions stay
/// on the old NPM with `tokenURI` reverting (their previous behaviour);
/// users can withdraw via the old contract and re-mint on the new one.
///
/// After deploy:
///   * mint a DID for the new NPM (otherwise it can't custody stocks)
///   * update `VITE_POSITION_MANAGER_CONTRACT` in the DEX workflow
///   * update CLAUDE.md / deployment manifest
contract RedeployNPMWithDescriptor is Script {
    /// Anvil/local hardhat default account #1 — usable only when the
    /// admin key isn't supplied AND the chain we're targeting is one
    /// of the known dev chains. Real environments must set
    /// `ADMIN_PRIVATE_KEY`.
    uint256 internal constant LOCAL_DEFAULT_KEY =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    function run(
        address v3Factory,
        address wdel,
        address did,
        address descriptor
    ) external returns (address positionManager) {
        require(v3Factory != address(0), "v3Factory required");
        require(wdel != address(0), "wdel required");
        require(did != address(0), "did required");
        require(descriptor != address(0), "descriptor required");

        uint256 adminKey = vm.envOr("ADMIN_PRIVATE_KEY", uint256(0));
        if (adminKey == 0) {
            require(
                block.chainid == 31337 || block.chainid == 1336,
                "ADMIN_PRIVATE_KEY required (default key is dev-only)"
            );
            adminKey = LOCAL_DEFAULT_KEY;
        }

        vm.startBroadcast(adminKey);

        DclexPositionManager npm = new DclexPositionManager(
            v3Factory,
            wdel,
            descriptor,
            IDID(did)
        );
        positionManager = address(npm);
        console.log("DclexPositionManager:", positionManager);

        // Mint DID for the new NPM so it can hold/transfer stocks.
        DigitalIdentity(did).mintAdmin(positionManager, 0, bytes32(0));
        console.log("DID minted for new PositionManager");

        vm.stopBroadcast();
    }
}
