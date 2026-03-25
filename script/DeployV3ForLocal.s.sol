// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {
    UniswapV3Factory
} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {WDEL} from "../src/WDEL.sol";
import {
    IWETH9
} from "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

/// @title DeployV3ForLocal
/// @notice Deploys WETH9 Mock and V3 infrastructure for local Anvil testing
contract DeployV3ForLocal is Script {
    function run()
        external
        returns (address weth, address v3Factory, address v3SwapRouter)
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

        vm.stopBroadcast();
    }
}
