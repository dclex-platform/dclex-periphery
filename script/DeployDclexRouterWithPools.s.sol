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
import {BatchPoolDeployer} from "src/BatchPoolDeployer.sol";
import {HelperConfig as DclexPeripheryHelperConfig} from "./HelperConfig.s.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployRouterWithPools is Script {
    // Struct to bundle deployment parameters and avoid stack depth issues
    struct DeploymentContext {
        Factory stocksFactory;
        uint256 maxPriceStaleness;
        ISwapRouter v3SwapRouter;
        IQuoter v3Quoter;
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
        IQuoter v3Quoter
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
            v3Quoter: v3Quoter
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

        // Deploy router
        vm.startBroadcast();
        IQuoter quoter = address(ctx.v3Quoter) != address(0)
            ? ctx.v3Quoter
            : result.config.v3Quoter;
        result.router = new DclexRouter(swapRouter, quoter, result.config.usdcToken);
        vm.stopBroadcast();

        // Deploy pools
        _deployPools(result.router, ctx.stocksFactory, result.protocolHelperConfig, ctx.maxPriceStaleness);

        // Setup DID and transfer ownership
        _finalizeDeployment(result.router, ctx.stocksFactory, result.config.admin);
    }

    /// @notice Deploy router and all pools via batch contract
    /// @dev Uses temporary permission delegation to enable single-transaction deployment
    function _deployRouterAndPoolsViaBatchContract(
        Factory stocksFactory,
        DclexProtocolHelperConfig dclexProtocolHelperConfig,
        uint256 maxPriceStaleness,
        ISwapRouter swapRouter,
        IWETH9 wethToken,
        IERC20 usdcToken,
        address admin
    ) private returns (DclexRouter) {
        DclexProtocolHelperConfig.NetworkConfig memory protocolConfig = dclexProtocolHelperConfig.getConfig();
        DigitalIdentity digitalIdentity = DigitalIdentity(address(stocksFactory.getDID()));

        // Collect stock addresses and price feed IDs
        uint256 symbolsCount = stocksFactory.getStocksCount();
        address[] memory stockAddresses = new address[](symbolsCount);
        bytes32[] memory priceFeedIds = new bytes32[](symbolsCount);

        for (uint256 i = 0; i < symbolsCount; ++i) {
            string memory symbol = stocksFactory.symbols(i);
            stockAddresses[i] = stocksFactory.stocks(symbol);
            priceFeedIds[i] = dclexProtocolHelperConfig.getPriceFeedId(symbol);
        }

        vm.startBroadcast();

        // Deploy router and batch deployer
        DclexRouter router = new DclexRouter(swapRouter, wethToken, usdcToken);
        BatchPoolDeployer batchDeployer = new BatchPoolDeployer();

        // Grant temporary permissions to batch deployer
        router.transferOwnership(address(batchDeployer));
        digitalIdentity.grantRole(digitalIdentity.DEFAULT_ADMIN_ROLE(), address(batchDeployer));

        // Deploy all pools in a single transaction
        batchDeployer.deployAllPools(
            router,
            stocksFactory,
            protocolConfig.usdcToken,
            protocolConfig.oracle,
            stockAddresses,
            priceFeedIds,
            maxPriceStaleness,
            admin
        );

        // Revoke batch deployer's admin role (router ownership already transferred in deployAllPools)
        digitalIdentity.revokeRole(digitalIdentity.DEFAULT_ADMIN_ROLE(), address(batchDeployer));

        vm.stopBroadcast();

        return router;
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
            v3Quoter: IQuoter(address(0))
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
