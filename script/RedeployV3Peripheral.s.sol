// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {DclexPositionManager} from "src/DclexPositionManager.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";

/// @notice Redeploys the V3 periphery contracts (SwapRouter / Quoter /
///         DclexPositionManager) against an existing DclexV3Factory + WDEL.
///         Used when the PoolAddress library's POOL_INIT_CODE_HASH was
///         stale at the time the first set was deployed — the Factory is
///         unaffected (it uses CREATE2 directly), but anything that
///         derives pool addresses off the stale hash needs to be rebuilt
///         against the corrected library.
contract RedeployV3Peripheral is Script {
    address constant FACTORY_CORE = 0xb39CA4095bf1E2e617df5aD898e058A58939C50F;

    struct Result {
        address swapRouter;
        address quoter;
        address positionManager;
    }

    function run(
        address v3Factory,
        address wdel,
        address did
    ) external returns (Result memory r) {
        uint256 adminKey = vm.envOr("ADMIN_PRIVATE_KEY", uint256(0));
        if (adminKey == 0) {
            adminKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        }

        vm.startBroadcast(adminKey);

        SwapRouter swapRouter = new SwapRouter(v3Factory, wdel);
        r.swapRouter = address(swapRouter);
        console.log("SwapRouter:", r.swapRouter);

        Quoter quoter = new Quoter(v3Factory, wdel);
        r.quoter = address(quoter);
        console.log("Quoter:", r.quoter);

        DclexPositionManager npm = new DclexPositionManager(
            v3Factory,
            wdel,
            address(0),
            IDID(did)
        );
        r.positionManager = address(npm);
        console.log("DclexPositionManager:", r.positionManager);

        // Mint DIDs for the 3 new contracts
        DigitalIdentity didContract = DigitalIdentity(did);
        didContract.mintAdmin(r.swapRouter, 0, bytes32(0));
        didContract.mintAdmin(r.quoter, 0, bytes32(0));
        didContract.mintAdmin(r.positionManager, 0, bytes32(0));
        console.log("DIDs minted for SwapRouter, Quoter, PositionManager");

        vm.stopBroadcast();
    }
}
