// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {DeployDclexPool} from "dclex-protocol/script/DeployDclexPool.s.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {HelperConfig as DclexProtocolHelperConfig} from "dclex-protocol/script/HelperConfig.s.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {HelperConfig as DclexPeripheryHelperConfig} from "./HelperConfig.s.sol";

contract DeployRouterWithPools is Script {
    function run(
        Factory stocksFactory
    )
        external
        returns (
            DclexRouter,
            DclexPeripheryHelperConfig.NetworkConfig memory,
            address,
            DclexProtocolHelperConfig
        )
    {
        DclexPeripheryHelperConfig helperConfig = new DclexPeripheryHelperConfig();
        DclexProtocolHelperConfig dclexProtocolHelperConfig = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig
            memory protocolConfig = dclexProtocolHelperConfig.getConfig();
        DeployDclexPool dclexPoolDeployer = new DeployDclexPool();

        DclexPeripheryHelperConfig.NetworkConfig memory config = helperConfig
            .getConfig(protocolConfig.usdcToken);
        uint256 symbolsCount = stocksFactory.getStocksCount();
        vm.startBroadcast();
        DclexRouter dclexRouter = new DclexRouter(
            config.uniswapV4PoolManager,
            config.ethUsdcPoolKey
        );
        vm.stopBroadcast();
        for (uint256 i = 0; i < symbolsCount; ++i) {
            string memory symbol = stocksFactory.symbols(i);
            address stockAddress = stocksFactory.stocks(symbol);
            DclexPool dclexPool = dclexPoolDeployer.run(
                IStock(stockAddress),
                dclexProtocolHelperConfig
            );
            vm.startBroadcast();
            dclexRouter.setPool(stockAddress, dclexPool);
            vm.stopBroadcast();
        }
        vm.startBroadcast();
        dclexRouter.transferOwnership(config.admin);
        vm.stopBroadcast();
        address pyth = address(dclexProtocolHelperConfig.getConfig().pyth);
        return (dclexRouter, config, pyth, dclexProtocolHelperConfig);
    }
}
