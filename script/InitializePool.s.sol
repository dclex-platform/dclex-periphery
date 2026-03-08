// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {HelperConfig as DclexProtocolHelperConfig} from "dclex-protocol/script/HelperConfig.s.sol";
import {Factory} from "dclex-mint/contracts/dclex/Factory.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DclexRouter} from "../src/DclexRouter.sol";

contract InitializePool is Script {
    function run(
        address routerAddress,
        address stocksFactoryAddress,
        string[] calldata stockSymbols,
        uint256 stockAmount,
        uint256 usdcAmount
    ) external {
        DclexProtocolHelperConfig dclexProtocolHelperConfig = new DclexProtocolHelperConfig();
        string[] memory inputs = new string[](2);
        inputs[0] = "./getPythData.sh";
        bytes[] memory pythData = new bytes[](2);
        DclexRouter dclexRouter = DclexRouter(payable(routerAddress));
        Factory stocksFactory = Factory(stocksFactoryAddress);
        vm.startBroadcast();
        if (block.chainid == 31337 || block.chainid == 2028) {}
        for (uint256 i = 0; i < stockSymbols.length; ++i) {
            address stockAddress = stocksFactory.stocks(stockSymbols[i]);
            if (block.chainid == 31337 || block.chainid == 2028) {
                pythData[0] = createMockPriceFeedUpdateData(
                    dclexProtocolHelperConfig.getPriceFeedId(stockSymbols[i]),
                    int64(uint64(1e18 / 1e10)),
                    10,
                    -8,
                    int64(uint64(1e18)),
                    10,
                    uint64(block.timestamp),
                    uint64(block.timestamp)
                );
                pythData[1] = createMockPriceFeedUpdateData(
                    dclexProtocolHelperConfig.getPriceFeedId("USDC"),
                    int64(uint64(1e18 / 1e10)),
                    10,
                    -8,
                    int64(uint64(1e18)),
                    10,
                    uint64(block.timestamp),
                    uint64(block.timestamp)
                );
            } else {
                inputs[1] = stockSymbols[i];
                pythData[0] = vm.parseBytes(vm.toString(vm.ffi(inputs)));
                pythData[1] = vm.parseBytes(vm.toString(vm.ffi(inputs)));
            }
            DclexPool pool = dclexRouter.stockTokenToPool(stockAddress);
            pool.stockToken().approve(address(pool), stockAmount);
            pool.usdcToken().approve(address(pool), usdcAmount);
            pool.initialize{value: 4}(stockAmount, usdcAmount, pythData);
        }
        vm.stopBroadcast();
    }

    function createMockPriceFeedUpdateData(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        int64 emaPrice,
        uint64 emaConf,
        uint64 publishTime,
        uint64 prevPublishTime
    ) public pure returns (bytes memory priceFeedData) {
        PythStructs.PriceFeed memory priceFeed;

        priceFeed.id = id;

        priceFeed.price.price = price;
        priceFeed.price.conf = conf;
        priceFeed.price.expo = expo;
        priceFeed.price.publishTime = publishTime;

        priceFeed.emaPrice.price = emaPrice;
        priceFeed.emaPrice.conf = emaConf;
        priceFeed.emaPrice.expo = expo;
        priceFeed.emaPrice.publishTime = publishTime;

        priceFeedData = abi.encode(priceFeed, prevPublishTime);
    }
}
