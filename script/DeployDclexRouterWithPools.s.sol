// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IStock} from "dclex-mint/contracts/interfaces/IStock.sol";
import {DigitalIdentity} from "dclex-mint/contracts/dclex/DigitalIdentity.sol";
import {DeployDclexPool} from "dclex-protocol/script/DeployDclexPool.s.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {HelperConfig as DclexProtocolHelperConfig} from "dclex-protocol/script/HelperConfig.s.sol";
import {Factory} from "dclex-mint/contracts/dclex/Factory.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {HelperConfig as DclexPeripheryHelperConfig} from "./HelperConfig.s.sol";

contract DeployRouterWithPools is Script {
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
        DclexProtocolHelperConfig dclexProtocolHelperConfig;
        DclexPeripheryHelperConfig.NetworkConfig memory config;
        vm.startBroadcast();
        DclexPeripheryHelperConfig helperConfig = new DclexPeripheryHelperConfig();
        vm.stopBroadcast();
        {
            dclexProtocolHelperConfig = new DclexProtocolHelperConfig();
            DclexProtocolHelperConfig.NetworkConfig
                memory protocolConfig = dclexProtocolHelperConfig.getConfig();
            config = helperConfig.getConfig(protocolConfig.usdcToken);
        }
        vm.startBroadcast();
        DclexRouter dclexRouter = new DclexRouter(
            config.uniswapV4PoolManager,
            config.ethUsdcPoolKey
        );
        vm.stopBroadcast();
        deployDclexPools(
            dclexRouter,
            stocksFactory,
            dclexProtocolHelperConfig,
            maxPriceStaleness
        );
        vm.startBroadcast();
        // Router needs a DID because it acts as intermediary for dUSD
        // in stock-to-stock swaps (receives from pool A, sends to pool B)
        DigitalIdentity digitalIdentity = DigitalIdentity(
            address(stocksFactory.getDID())
        );
        digitalIdentity.mintAdmin(address(dclexRouter), 2, bytes32(0));
        dclexRouter.transferOwnership(config.admin);
        vm.stopBroadcast();
        return (
            dclexRouter,
            config,
            address(dclexProtocolHelperConfig.getConfig().oracle),
            dclexProtocolHelperConfig,
            helperConfig
        );
    }

    function deployDclexPools(
        DclexRouter dclexRouter,
        Factory stocksFactory,
        DclexProtocolHelperConfig dclexProtocolHelperConfig,
        uint256 maxPriceStaleness
    ) private {
        DeployDclexPool dclexPoolDeployer = new DeployDclexPool();
        DigitalIdentity digitalIdentity = DigitalIdentity(
            address(stocksFactory.getDID())
        );
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
}
