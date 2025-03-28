// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "dclex-mint/contracts/dclex/Factory.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DclexRouter} from "../src/DclexRouter.sol";

contract InitializePool is Script {
    function run(
        address routerAddress,
        address stocksFactoryAddress,
        string[] calldata stockSymbols,
        uint256 stockAmount,
        uint256 usdcAmount,
        bytes[] calldata pythData
    ) external {
        DclexRouter dclexRouter = DclexRouter(payable(routerAddress));
        Factory stocksFactory = Factory(stocksFactoryAddress);
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        for (uint256 i = 0; i < stockSymbols.length; ++i) {
            address stockAddress = stocksFactory.stocks(stockSymbols[i]);
            DclexPool pool = dclexRouter.stockTokenToPool(stockAddress);
            pool.stockToken().approve(address(pool), stockAmount);
            pool.usdcToken().approve(address(pool), usdcAmount);
            pool.initialize{value: 2}(stockAmount, usdcAmount, pythData);
        }
        vm.stopBroadcast();
    }
}
