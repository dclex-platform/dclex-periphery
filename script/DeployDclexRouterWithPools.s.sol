// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
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

        IQuoter quoter = address(ctx.v3Quoter) != address(0)
            ? ctx.v3Quoter
            : result.config.v3Quoter;

        // Deploy router + all pools via batch contract (single tx for all pools)
        result.router = _deployRouterAndPoolsViaBatchContract(
            ctx.stocksFactory,
            result.protocolHelperConfig,
            ctx.maxPriceStaleness,
            swapRouter,
            quoter,
            result.config.usdcToken,
            result.config.admin
        );
    }

    /// @notice Deploy router and all pools via batch contract (single tx for all pools)
    /// @dev Uses temporary permission delegation to enable single-transaction deployment
    struct BatchDeployParams {
        Factory stocksFactory;
        DclexProtocolHelperConfig protocolHelperConfig;
        uint256 maxPriceStaleness;
        ISwapRouter swapRouter;
        IQuoter quoter;
        IERC20 usdcToken;
        address admin;
    }

    function _deployRouterAndPoolsViaBatchContract(
        Factory stocksFactory,
        DclexProtocolHelperConfig protocolHelperConfig,
        uint256 maxPriceStaleness,
        ISwapRouter swapRouter,
        IQuoter quoter,
        IERC20 usdcToken,
        address admin
    ) private returns (DclexRouter) {
        return _executeBatchDeploy(BatchDeployParams(
            stocksFactory, protocolHelperConfig, maxPriceStaleness,
            swapRouter, quoter, usdcToken, admin
        ));
    }

    function _executeBatchDeploy(BatchDeployParams memory p) private returns (DclexRouter) {
        DclexProtocolHelperConfig.NetworkConfig memory cfg = p.protocolHelperConfig.getConfig();
        (address[] memory stocks, bytes32[] memory feeds) = _collectStockData(p.stocksFactory, p.protocolHelperConfig);

        vm.startBroadcast();

        DclexRouter router = new DclexRouter(p.swapRouter, p.quoter, p.usdcToken);
        BatchPoolDeployer batch = new BatchPoolDeployer();
        DigitalIdentity did = DigitalIdentity(address(p.stocksFactory.getDID()));

        router.transferOwnership(address(batch));
        did.grantRole(did.DEFAULT_ADMIN_ROLE(), address(batch));
        batch.deployAllPools(BatchPoolDeployer.DeployParams(
            router, p.stocksFactory, cfg.usdcToken, cfg.oracle,
            stocks, feeds, p.maxPriceStaleness, p.admin
        ));
        did.revokeRole(did.DEFAULT_ADMIN_ROLE(), address(batch));

        vm.stopBroadcast();
        return router;
    }

    function _collectStockData(
        Factory stocksFactory,
        DclexProtocolHelperConfig helperConfig
    ) private returns (address[] memory stocks, bytes32[] memory feeds) {
        uint256 n = stocksFactory.getStocksCount();
        stocks = new address[](n);
        feeds = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory sym = stocksFactory.symbols(i);
            stocks[i] = stocksFactory.stocks(sym);
            feeds[i] = helperConfig.getPriceFeedId(sym);
        }
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
