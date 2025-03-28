// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USDCMock} from "dclex-mint/contracts/mocks/USDCMock.sol";

contract InitializeUniswapV4Pool is Script {
    uint256 private ETH_USDC_PRICE = 3000;
    uint256 private constant PRICE_RANGE = 10;

    function run(IERC20 usdcToken) external {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig(
            usdcToken
        );
        run(config);
    }

    function run(HelperConfig.NetworkConfig memory config) public {
        int24 tickSpacing = 60;
        uint256 ethAmount = 0.01 ether;
        uint256 usdcAmount = 30e6;
        uint160 sqrtPriceX96 = sqrtX96(ETH_USDC_PRICE);
        uint160 sqrtPriceAX96 = sqrtX96(ETH_USDC_PRICE - PRICE_RANGE);
        uint160 sqrtPriceBX96 = sqrtX96(ETH_USDC_PRICE + PRICE_RANGE);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            ethAmount,
            usdcAmount
        );
        IPoolManager.ModifyLiquidityParams
            memory addLiquidityParams = IPoolManager.ModifyLiquidityParams({
                tickLower: tickSpacing *
                    (TickMath.getTickAtSqrtPrice(sqrtPriceAX96) / tickSpacing),
                tickUpper: tickSpacing *
                    (TickMath.getTickAtSqrtPrice(sqrtPriceBX96) / tickSpacing),
                liquidityDelta: int128(liquidity),
                salt: bytes32(0)
            });
        vm.startBroadcast();
        config.uniswapV4PoolManager.initialize(
            config.ethUsdcPoolKey,
            sqrtPriceX96
        );
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(
                config.uniswapV4PoolManager
            );
        config.usdcToken.approve(address(modifyLiquidityRouter), usdcAmount);
        // TODO: for some reason adding liquidity requires some more ether than calculated
        modifyLiquidityRouter.modifyLiquidity{value: 2 * ethAmount}(
            config.ethUsdcPoolKey,
            addLiquidityParams,
            ""
        );
        vm.stopBroadcast();
    }

    function sqrtX96(uint256 value) private returns (uint160) {
        return uint160((Math.sqrt(value * 1e24) * 2 ** 96) / 1e18);
    }
}
