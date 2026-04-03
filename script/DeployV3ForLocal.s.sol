// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {
    UniswapV3Factory
} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {
    NonfungiblePositionManager
} from "@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol";
import {WDEL} from "../src/WDEL.sol";
/// @title DeployV3ForLocal
/// @notice Deploys full V3 infrastructure: WDEL, Factory, SwapRouter, Quoter, NonfungiblePositionManager
contract DeployV3ForLocal is Script {
    function run()
        external
        returns (
            address weth,
            address v3Factory,
            address v3SwapRouter,
            address v3Quoter,
            address v3PositionManager
        )
    {
        vm.startBroadcast();

        // Deploy WDEL
        WDEL wethMock = new WDEL();
        weth = address(wethMock);
        console.log("WDEL deployed at:", weth);

        // Deploy V3 Factory
        UniswapV3Factory factory = new UniswapV3Factory();
        v3Factory = address(factory);
        console.log("UniswapV3Factory deployed at:", v3Factory);

        // Deploy SwapRouter
        SwapRouter swapRouter = new SwapRouter(v3Factory, weth);
        v3SwapRouter = address(swapRouter);
        console.log("V3 SwapRouter deployed at:", v3SwapRouter);

        // Deploy Quoter
        Quoter quoter = new Quoter(v3Factory, weth);
        v3Quoter = address(quoter);
        console.log("V3 Quoter deployed at:", v3Quoter);

        // Deploy NonfungiblePositionManager (tokenDescriptor=address(0) for local dev)
        NonfungiblePositionManager positionManager = new NonfungiblePositionManager(
            v3Factory,
            weth,
            address(0)
        );
        v3PositionManager = address(positionManager);
        console.log("V3 PositionManager deployed at:", v3PositionManager);

        vm.stopBroadcast();
    }
}
