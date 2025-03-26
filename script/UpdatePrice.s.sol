// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig as DclexProtocolHelperConfig} from "dclex-protocol/script/HelperConfig.s.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

contract UpdatePrice is Script {
    function run(
        address pyth,
        string calldata stockSymbol,
        uint256 price
    ) external {
        DclexProtocolHelperConfig dclexProtocolHelperConfig = new DclexProtocolHelperConfig();
        bytes32 priceFeedId = dclexProtocolHelperConfig.getPriceFeedId(
            stockSymbol
        );
        IPyth mockPyth = IPyth(pyth);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = createPriceFeedUpdateData(
            priceFeedId,
            int64(uint64(price / 1e10)),
            10,
            -8,
            int64(uint64(price)),
            10,
            uint64(block.timestamp)
        );
        uint256 value = mockPyth.getUpdateFee(updateData);
        vm.startBroadcast();
        mockPyth.updatePriceFeeds{value: value}(updateData);
        vm.stopBroadcast();
    }

    function createPriceFeedUpdateData(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        int64 emaPrice,
        uint64 emaConf,
        uint64 publishTime
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

        priceFeedData = abi.encode(priceFeed);
    }
}
