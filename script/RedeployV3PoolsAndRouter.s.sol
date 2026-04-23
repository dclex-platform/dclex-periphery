// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DclexV3Factory} from "src/DclexV3Factory.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

interface IOldRouter {
    function allStockTokens() external view returns (address[] memory);
    function stockPoolType(address token) external view returns (uint8);
    function stockToCustomPool(address token) external view returns (address);
}

/// @notice Creates 3 new V3 AMM pools on the new DclexV3Factory, initializes
///         them with the target prices, mints DIDs, deploys a new DclexRouter
///         wired to the new V3 SwapRouter/Quoter, copies the 44 custom pool
///         mappings from the current router, and registers the 3 new AMM pools.
/// @dev Run with FOUNDRY_PROFILE=default (Cancun OK for this repo's compilation)
///      and FOUNDRY_EVM_VERSION=shanghai at broadcast time.
contract RedeployV3PoolsAndRouter is Script {
    // primelta-dev — 2026-04-21 deployment
    address constant OLD_ROUTER = 0x1D1aEE6D5dC35F3c15E2D11083D0e59C026b64c4;
    address constant DUSD = 0x1A71DF49ea92867bda910b948Da588383a0450Ee;
    address constant FACTORY = 0xb39CA4095bf1E2e617df5aD898e058A58939C50F;
    address constant ADMIN = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    address constant WDEL = 0x1bb6D126516554F935cF8C0E9C70280088A5CE60;
    address constant AMMT1 = 0x7944ae74CC109A300FB375001b825caf7870B4b7;
    address constant AMMT2 = 0x972561188FF2C3DBebe4E60D158dee9623b8048A;

    uint24 constant FEE_TIER = 3000;

    struct Result {
        address newRouter;
        address wdelPool;
        address ammt1Pool;
        address ammt2Pool;
    }

    function run(
        DclexV3Factory v3Factory,
        ISwapRouter v3SwapRouter,
        IQuoter v3Quoter
    ) external returns (Result memory r) {
        uint256 adminKey = vm.envOr("ADMIN_PRIVATE_KEY", uint256(0));
        if (adminKey == 0) {
            adminKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        }

        DigitalIdentity did = DigitalIdentity(
            address(Factory(FACTORY).getDID())
        );

        vm.startBroadcast(adminKey);

        // Create + initialize the 3 V3 pools
        r.wdelPool = _createAndInitPool(v3Factory, WDEL, 10e6);      // $10 per WDEL
        r.ammt1Pool = _createAndInitPool(v3Factory, AMMT1, 10e6);    // $10 per AMMT1
        r.ammt2Pool = _createAndInitPool(v3Factory, AMMT2, 20e6);    // $20 per AMMT2

        // Sanity-check PoolAddress library derivation matches Factory output.
        // If POOL_INIT_CODE_HASH is stale this MUST revert.
        _assertPoolAddressDerivationMatches(address(v3Factory), WDEL, r.wdelPool);
        _assertPoolAddressDerivationMatches(address(v3Factory), AMMT1, r.ammt1Pool);
        _assertPoolAddressDerivationMatches(address(v3Factory), AMMT2, r.ammt2Pool);

        // Mint DIDs for each new pool
        if (did.balanceOf(r.wdelPool) == 0) {
            did.mintAdmin(r.wdelPool, 0, bytes32(0));
        }
        if (did.balanceOf(r.ammt1Pool) == 0) {
            did.mintAdmin(r.ammt1Pool, 0, bytes32(0));
        }
        if (did.balanceOf(r.ammt2Pool) == 0) {
            did.mintAdmin(r.ammt2Pool, 0, bytes32(0));
        }

        // Deploy new DclexRouter
        DclexRouter newRouter = new DclexRouter(
            v3SwapRouter,
            v3Quoter,
            IERC20(DUSD)
        );
        r.newRouter = address(newRouter);

        // Copy custom pool mappings from old router
        IOldRouter oldRouter = IOldRouter(OLD_ROUTER);
        address[] memory tokens = oldRouter.allStockTokens();
        uint256 customCount;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (oldRouter.stockPoolType(tokens[i]) == 1) {
                address pool = oldRouter.stockToCustomPool(tokens[i]);
                newRouter.setCustomPool(tokens[i], DclexPool(pool));
                customCount++;
            }
        }
        console.log("Custom pools copied:", customCount);

        // Register new V3 AMM pools
        newRouter.setAMMPool(WDEL, r.wdelPool, FEE_TIER);
        newRouter.setAMMPool(AMMT1, r.ammt1Pool, FEE_TIER);
        newRouter.setAMMPool(AMMT2, r.ammt2Pool, FEE_TIER);
        console.log("AMM pools registered: 3");

        // Router DID for stock-to-stock intermediate dUSD transfers
        if (did.balanceOf(r.newRouter) == 0) {
            did.mintAdmin(r.newRouter, 2, bytes32(0));
        }

        newRouter.transferOwnership(ADMIN);

        vm.stopBroadcast();

        console.log("\n=== Redeploy complete ===");
        console.log("New DclexRouter:", r.newRouter);
        console.log("WDEL/dUSD V3 pool:", r.wdelPool);
        console.log("AMMT1/dUSD V3 pool:", r.ammt1Pool);
        console.log("AMMT2/dUSD V3 pool:", r.ammt2Pool);
    }

    function _createAndInitPool(
        DclexV3Factory v3Factory,
        address token,
        uint256 priceUsd
    ) private returns (address pool) {
        address token0 = token < DUSD ? token : DUSD;
        address token1 = token < DUSD ? DUSD : token;

        pool = v3Factory.getPool(token0, token1, FEE_TIER);
        if (pool == address(0)) {
            pool = v3Factory.createPool(token0, token1, FEE_TIER);
            console.log("Created pool:", pool);
        } else {
            console.log("Pool already exists:", pool);
        }

        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        if (sqrtPriceX96 == 0) {
            uint160 initSqrtPriceX96 = _calcSqrtPrice(token, priceUsd);
            IUniswapV3Pool(pool).initialize(initSqrtPriceX96);
            console.log("Initialized at sqrtPriceX96:", uint256(initSqrtPriceX96));
        }
    }

    /// @dev Mirror of DeployAMMStocks._calcSqrtPrice — keep in sync.
    function _calcSqrtPrice(
        address stockToken,
        uint256 priceUsd
    ) private pure returns (uint160) {
        bool stockIsToken0 = stockToken < DUSD;
        if (stockIsToken0) {
            uint256 sqrtPrice = Math.sqrt(priceUsd);
            return uint160((sqrtPrice << 96) / 1e9);
        } else {
            uint256 sqrtUsdc = Math.sqrt(priceUsd);
            return uint160((1e9 << 96) / sqrtUsdc);
        }
    }

    function _assertPoolAddressDerivationMatches(
        address factory,
        address token,
        address actual
    ) private pure {
        PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(token, DUSD, FEE_TIER);
        address derived = PoolAddress.computeAddress(factory, key);
        require(derived == actual, "POOL_INIT_CODE_HASH drift: derived != actual pool");
    }
}
