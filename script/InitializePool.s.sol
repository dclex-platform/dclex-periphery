// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {DclexRouter} from "../src/DclexRouter.sol";

contract InitializePool is Script {
    function run(
        address routerAddress,
        address stocksFactoryAddress,
        string[] calldata stockSymbols,
        uint256 stockAmount,
        uint256 usdcAmount
    ) external {
        DclexRouter dclexRouter = DclexRouter(payable(routerAddress));
        Factory stocksFactory = Factory(stocksFactoryAddress);
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        for (uint256 i = 0; i < stockSymbols.length; ++i) {
            address stockAddress = stocksFactory.stocks(stockSymbols[i]);
            DclexPool pool = dclexRouter.stockTokenToPool(stockAddress);
            pool.stockToken().approve(address(pool), stockAmount);
            pool.usdcToken().approve(address(pool), usdcAmount);
            pool.initialize(stockAmount, usdcAmount, new bytes[](0));
        }
        vm.stopBroadcast();
    }
}
