// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {DeployDclexPool} from "dclex-protocol/script/DeployDclexPool.s.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {HelperConfig as DclexPeripheryHelperConfig} from "./HelperConfig.s.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IWETH9} from "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployRouterWithPools is Script {
    // Struct to bundle deployment parameters and avoid stack depth issues
    struct DeploymentContext {
        Factory stocksFactory;
        uint256 maxPriceStaleness;
        ISwapRouter v3SwapRouter;
        IWETH9 weth;
    }

    // Struct to bundle return values
    struct DeploymentResult {
        DclexRouter router;
        DclexPeripheryHelperConfig.NetworkConfig config;
        address oracleAddress;
        DclexProtocolHelperConfig protocolHelperConfig;
        DclexPeripheryHelperConfig peripheryHelperConfig;
    }

    function run(
        Factory stocksFactory,
        uint256 maxPriceStaleness,
        ISwapRouter v3SwapRouter,
        IWETH9 weth
    )
        external
        returns (
            DclexRouter,
            DclexPeripheryHelperConfig.NetworkConfig memory,
            address,
            DclexProtocolHelperConfig,
            DclexPeripheryHelperConfig
        )
    {
        DeploymentContext memory ctx = DeploymentContext({
            stocksFactory: stocksFactory,
            maxPriceStaleness: maxPriceStaleness,
            v3SwapRouter: v3SwapRouter,
            weth: weth
        });

        DeploymentResult memory result = _deploy(ctx);

        return (
            result.router,
            result.config,
            result.oracleAddress,
            result.protocolHelperConfig,
            result.peripheryHelperConfig
        );
    }

    function _deploy(DeploymentContext memory ctx) private returns (DeploymentResult memory result) {
        // Initialize helper configs
        vm.startBroadcast();
        result.peripheryHelperConfig = new DclexPeripheryHelperConfig();
        vm.stopBroadcast();

        result.protocolHelperConfig = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig memory protocolConfig = result.protocolHelperConfig.getConfig();
        result.config = result.peripheryHelperConfig.getConfig(protocolConfig.usdcToken);
        result.oracleAddress = address(protocolConfig.oracle);

        // Resolve V3 infrastructure
        ISwapRouter swapRouter = address(ctx.v3SwapRouter) != address(0)
            ? ctx.v3SwapRouter
            : result.config.v3SwapRouter;
        IWETH9 wethToken = address(ctx.weth) != address(0) ? ctx.weth : result.config.weth;

        // Deploy router
        vm.startBroadcast();
        result.router = new DclexRouter(swapRouter, wethToken, result.config.usdcToken);
        vm.stopBroadcast();

        // Deploy pools
        _deployPools(result.router, ctx.stocksFactory, result.protocolHelperConfig, ctx.maxPriceStaleness);

        // Setup DID and transfer ownership
        _finalizeDeployment(result.router, ctx.stocksFactory, result.config.admin);
    }

    function _deployPools(
        DclexRouter dclexRouter,
        Factory stocksFactory,
        DclexProtocolHelperConfig dclexProtocolHelperConfig,
        uint256 maxPriceStaleness
    ) private {
        DeployDclexPool dclexPoolDeployer = new DeployDclexPool();
        DigitalIdentity digitalIdentity = DigitalIdentity(address(stocksFactory.getDID()));
        uint256 symbolsCount = stocksFactory.getStocksCount();

        for (uint256 i = 0; i < symbolsCount; ++i) {
            string memory symbol = stocksFactory.symbols(i);
            address stockAddress = stocksFactory.stocks(symbol);
            DclexPool dclexPool = dclexPoolDeployer.run(
                IStock(stockAddress),
                dclexProtocolHelperConfig,
                maxPriceStaleness
            );
            vm.startBroadcast();
            dclexRouter.setPool(stockAddress, dclexPool);
            digitalIdentity.mintAdmin(address(dclexPool), 2, bytes32(0));
            vm.stopBroadcast();
        }
    }

    function _finalizeDeployment(
        DclexRouter dclexRouter,
        Factory stocksFactory,
        address admin
    ) private {
        vm.startBroadcast();
        // Router needs a DID because it acts as intermediary for dUSD
        // in stock-to-stock swaps (receives from pool A, sends to pool B)
        DigitalIdentity digitalIdentity = DigitalIdentity(address(stocksFactory.getDID()));
        digitalIdentity.mintAdmin(address(dclexRouter), 2, bytes32(0));
        dclexRouter.transferOwnership(admin);
        vm.stopBroadcast();
    }

    /// @notice Simplified deployment without external V3 params
    function run(
        Factory stocksFactory,
        uint256 maxPriceStaleness
    )
        external
        returns (
            DclexRouter,
            DclexPeripheryHelperConfig.NetworkConfig memory,
            address,
            DclexProtocolHelperConfig,
            DclexPeripheryHelperConfig
        )
    {
        DeploymentContext memory ctx = DeploymentContext({
            stocksFactory: stocksFactory,
            maxPriceStaleness: maxPriceStaleness,
            v3SwapRouter: ISwapRouter(address(0)),
            weth: IWETH9(address(0))
        });

        DeploymentResult memory result = _deploy(ctx);

        return (
            result.router,
            result.config,
            result.oracleAddress,
            result.protocolHelperConfig,
            result.peripheryHelperConfig
        );
    }
}
