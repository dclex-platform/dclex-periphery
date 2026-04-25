// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TickLens} from "@uniswap/v3-periphery/contracts/lens/TickLens.sol";

/// @title DeployTickLens
/// @notice Deploys the stateless TickLens helper used by the DEX add-liquidity
///         range-selector chart. TickLens has no constructor args, no owner,
///         no DID — pool address is passed per call. One deploy works for
///         every present and future UniswapV3Pool created via DclexV3Factory.
contract DeployTickLens is Script {
    function run() external returns (address tickLens) {
        uint256 adminKey = vm.envOr("ADMIN_PRIVATE_KEY", uint256(0));
        if (adminKey == 0) {
            adminKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        }

        vm.startBroadcast(adminKey);
        TickLens lens = new TickLens();
        tickLens = address(lens);
        vm.stopBroadcast();

        console.log("TickLens deployed at:", tickLens);
    }
}
