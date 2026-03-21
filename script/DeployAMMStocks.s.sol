// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {V3LiquidityHelper} from "./helpers/V3LiquidityHelper.sol";
import {
    UniswapV3Factory
} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {
    IUniswapV3Factory
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {
    LiquidityAmounts
} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {
    ISwapRouter
} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {
    IWETH9
} from "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import {WDEL} from "../src/WDEL.sol";

/// @title DeployAMMStocks
/// @notice Deploys AMM test stocks with V3 pools for testing the V3 integration
contract DeployAMMStocks is Script {
    uint24 public constant FEE_TIER = 3000; // 0.3%
    int24 internal constant MIN_TICK = -887220; // Full range lower bound
    int24 internal constant MAX_TICK = 887220; // Full range upper bound

    // Deployment context to avoid stack issues
    Factory internal _factory;
    DclexRouter internal _router;
    IERC20 internal _usdc;
    IUniswapV3Factory internal _v3Factory;
    V3LiquidityHelper internal _liquidityHelper;
    DigitalIdentity internal _did;
    IWETH9 internal _weth;

    struct DeploymentResult {
        address[] stockAddresses;
        address[] v3PoolAddresses;
        address v3Factory;
        address swapRouter;
        address wdelPool; // wDEL/dUSD pool address
    }

    // Configurable wDEL liquidity amount (set via runLocalWithConfig)
    uint256 internal _wdelLiquidityAmount = 5_000 ether; // Default 5K wDEL

    /// @notice Simplified run for shell script with only essential params
    function runLocal(
        address factoryAddr,
        address routerAddr,
        address usdcAddr
    ) external returns (DeploymentResult memory) {
        return _runLocalInternal(factoryAddr, routerAddr, usdcAddr);
    }

    /// @notice Run with configurable wDEL liquidity amount
    function runLocalWithConfig(
        address factoryAddr,
        address routerAddr,
        address usdcAddr,
        uint256 wdelLiquidityAmount
    ) external returns (DeploymentResult memory) {
        _wdelLiquidityAmount = wdelLiquidityAmount;
        return _runLocalInternal(factoryAddr, routerAddr, usdcAddr);
    }

    function _runLocalInternal(
        address factoryAddr,
        address routerAddr,
        address usdcAddr
    ) internal returns (DeploymentResult memory) {
        _factory = Factory(factoryAddr);
        _router = DclexRouter(payable(routerAddr));
        _usdc = IERC20(usdcAddr);
        _did = DigitalIdentity(address(_factory.getDID()));

        // Check if V3 infrastructure exists via router
        ISwapRouter existingRouter = _router.v3SwapRouter();
        IWETH9 existingWeth = _router.weth();

        address swapRouterAddr;
        if (
            address(existingRouter) == address(0) ||
            address(existingWeth) == address(0)
        ) {
            console.log("V3 infrastructure not found, deploying...");
            (_v3Factory, swapRouterAddr) = _deployV3Infrastructure();
        } else {
            console.log(
                "Using existing V3 SwapRouter:",
                address(existingRouter)
            );
            swapRouterAddr = address(existingRouter);
            _weth = existingWeth;
            // Use the SAME factory that the SwapRouter uses (critical for routing to work)
            _v3Factory = IUniswapV3Factory(
                SwapRouter(payable(swapRouterAddr)).factory()
            );
            console.log("Using existing V3 Factory:", address(_v3Factory));
        }

        // Deploy liquidity helper contract
        vm.startBroadcast();
        _liquidityHelper = new V3LiquidityHelper();
        console.log(
            "V3LiquidityHelper deployed at:",
            address(_liquidityHelper)
        );

        // Mint DID for the liquidity helper
        if (_did.balanceOf(address(_liquidityHelper)) == 0) {
            _did.mintAdmin(address(_liquidityHelper), 0, bytes32(0));
            console.log("Minted DID for liquidity helper");
        }
        vm.stopBroadcast();

        // Deploy AMM stocks
        DeploymentResult memory result;
        result.stockAddresses = new address[](2);
        result.v3PoolAddresses = new address[](2);
        result.v3Factory = address(_v3Factory);
        result.swapRouter = swapRouterAddr;

        // Stock 1: AMMT1 at $10 with 100,000 stocks single-side liquidity
        (result.stockAddresses[0], result.v3PoolAddresses[0]) = _deployAMMStock(
            "AMM Test Stock 1",
            "AMMT1",
            10e6, // $10
            100_000e18, // 100K stocks liquidity (single-side)
            0 // Not used for single-side
        );

        // Stock 2: AMMT2 at $20 with 100,000 stocks single-side liquidity
        (result.stockAddresses[1], result.v3PoolAddresses[1]) = _deployAMMStock(
            "AMM Test Stock 2",
            "AMMT2",
            20e6, // $20
            100_000e18, // 100K stocks liquidity (single-side)
            0 // Not used for single-side
        );

        // Deploy wDEL/dUSD pool - separate broadcast to isolate potential failures
        result.wdelPool = _deployWdelPoolSafe();

        return result;
    }

    /// @notice Safe wrapper for wDEL pool deployment that won't revert the entire script
    function _deployWdelPoolSafe() private returns (address) {
        // wDEL pool deployment is optional - if it fails, we still have AMMT1/AMMT2
        return _deployWdelPool();
    }

    /// @notice Deploy wDEL/dUSD pool with full-range liquidity at lowest tick
    function _deployWdelPool() private returns (address poolAddr) {
        if (address(_weth) == address(0)) {
            console.log("WETH/wDEL not available, skipping wDEL pool");
            return address(0);
        }

        console.log("Deploying wDEL/dUSD pool...");

        // Create pool for wDEL/dUSD
        address token0 = address(_weth) < address(_usdc)
            ? address(_weth)
            : address(_usdc);
        address token1 = address(_weth) < address(_usdc)
            ? address(_usdc)
            : address(_weth);

        vm.startBroadcast();

        poolAddr = _v3Factory.getPool(token0, token1, FEE_TIER);
        if (poolAddr == address(0)) {
            poolAddr = _v3Factory.createPool(token0, token1, FEE_TIER);
            console.log("Created wDEL/dUSD pool at:", poolAddr);
        } else {
            console.log("wDEL/dUSD pool already exists at:", poolAddr);
        }

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        if (sqrtPriceX96 == 0) {
            // Initialize wDEL at $0.01 (1e4 in 6 decimals)
            uint160 initSqrtPriceX96 = _calcSqrtPrice(address(_weth), 1e4);
            pool.initialize(initSqrtPriceX96);
            console.log("Initialized wDEL/dUSD pool at $0.01");
            console.log("  sqrtPriceX96:", uint256(initSqrtPriceX96));
        }

        // Mint DID for pool if needed
        if (_did.balanceOf(poolAddr) == 0) {
            _did.mintAdmin(poolAddr, 0, bytes32(0));
            console.log("Minted DID for wDEL/dUSD pool");
        }

        // Mint DID for wDEL token itself (needed for transfers)
        if (_did.balanceOf(address(_weth)) == 0) {
            _did.mintAdmin(address(_weth), 0, bytes32(0));
            console.log("Minted DID for wDEL token");
        }

        vm.stopBroadcast();

        // Register wDEL with router as AMM pool so it appears in allStockTokens()
        // Do this BEFORE liquidity so even if liquidity fails, wDEL is registered
        vm.startBroadcast();
        _router.setAMMPool(address(_weth), poolAddr);
        console.log("Registered wDEL with router as AMM pool");
        vm.stopBroadcast();

        _addWdelLiquidity(poolAddr);

        return poolAddr;
    }

    /// @notice Add two-sided liquidity to wDEL/dUSD pool
    function _addWdelLiquidity(address poolAddr) private {
        // Use configurable wDEL amount (set via runLocalWithConfig or default 5K)
        uint256 wdelAmount = _wdelLiquidityAmount;
        // Calculate USDC needed at $0.01 per wDEL (cheap initial price)
        uint256 usdcAmount = (wdelAmount * 1e4) / 1e18; // $0.01 = 1e4 in 6 decimals

        // Fund liquidity helper with wDEL and USDC
        vm.startBroadcast();

        // Mint wDEL to helper (use mint for testing)
        WDEL(payable(address(_weth))).mint(
            address(_liquidityHelper),
            wdelAmount
        );
        console.log("Sent wDEL to liquidity helper:", wdelAmount);

        // Mint USDC to helper
        IERC20Mintable(address(_usdc)).mint(address(_liquidityHelper), usdcAmount);
        console.log("Sent USDC to liquidity helper:", usdcAmount);

        vm.stopBroadcast();

        // Add two-sided liquidity
        _addTwoSidedLiquidity(poolAddr, address(_weth));
    }

    /// @notice Add single-side liquidity (only one token, below current price)
    function _addSingleSideLiquidity(
        address poolAddr,
        address tokenAddr,
        uint256 amount,
        bool /* belowPrice - always true for now */
    ) private {
        console.log("Adding single-side liquidity:");
        console.log("  token:", tokenAddr);
        console.log("  amount:", amount);

        // Calculate tick range and liquidity
        (
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidityAmount
        ) = _calcSingleSideLiquidityParams(poolAddr, amount);

        console.log("  Calculated liquidity:", uint256(liquidityAmount));

        if (liquidityAmount == 0) {
            console.log("  WARNING: Zero liquidity, skipping");
            return;
        }

        vm.startBroadcast();
        _executeSingleSideAdd(
            poolAddr,
            tokenAddr,
            tickLower,
            tickUpper,
            liquidityAmount
        );
        _liquidityHelper.withdraw(tokenAddr, msg.sender);
        vm.stopBroadcast();
    }

    function _calcSingleSideLiquidityParams(
        address poolAddr,
        uint256 amount
    )
        private
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidityAmount)
    {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        (, int24 currentTick, , , , , ) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        // Round current tick DOWN to valid tick
        int24 roundedTick = (currentTick / tickSpacing) * tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            roundedTick -= tickSpacing;
        }

        // For single-sided token0 liquidity, position must be BELOW current tick
        // Set tickUpper to one tickSpacing below current to ensure it's fully below
        tickLower = MIN_TICK + 120;
        tickUpper = roundedTick - tickSpacing;

        // Ensure valid tick range
        if (tickUpper <= tickLower) {
            tickUpper = tickLower + tickSpacing;
        }

        // Calculate liquidity
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidityAmount = LiquidityAmounts.getLiquidityForAmount0(
            sqrtLower,
            sqrtUpper,
            amount
        );
    }

    function _executeSingleSideAdd(
        address poolAddr,
        address tokenAddr,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityAmount
    ) private {
        try
            _liquidityHelper.addLiquiditySingleSide(
                poolAddr,
                tokenAddr,
                tickLower,
                tickUpper,
                liquidityAmount
            )
        returns (uint256 usedAmount) {
            console.log("  Added single-side liquidity, used:", usedAmount);
        } catch {
            console.log("  Single-side addLiquidity failed");
        }
    }

    function _deployV3Infrastructure()
        private
        returns (IUniswapV3Factory, address)
    {
        vm.startBroadcast();

        // Deploy WETH9 mock (wDEL on Primelta chain)
        WDEL weth = new WDEL();
        console.log("WDEL (wDEL) deployed at:", address(weth));
        _weth = IWETH9(address(weth));

        // Deploy V3 Factory
        UniswapV3Factory factory = new UniswapV3Factory();
        console.log("UniswapV3Factory deployed at:", address(factory));

        // Deploy SwapRouter
        SwapRouter swapRouter = new SwapRouter(address(factory), address(weth));
        console.log("SwapRouter deployed at:", address(swapRouter));

        vm.stopBroadcast();

        return (IUniswapV3Factory(address(factory)), address(swapRouter));
    }

    function _deployAMMStock(
        string memory name,
        string memory symbol,
        uint256 priceUsd,
        uint256 stockLiquidity,
        uint256 /* usdcLiquidity - not used, calculated from price */
    ) private returns (address stockAddr, address poolAddr) {
        // 1. Create stock via Factory
        vm.startBroadcast();
        address existingStock = _factory.stocks(symbol);
        if (existingStock == address(0)) {
            string[] memory names = new string[](1);
            string[] memory symbols = new string[](1);
            names[0] = name;
            symbols[0] = symbol;
            _factory.createStocks(names, symbols);
            stockAddr = _factory.stocks(symbol);
            console.log("Created stock:", symbol, "at:", stockAddr);
        } else {
            stockAddr = existingStock;
            console.log("Stock already exists:", symbol, "at:", stockAddr);
        }
        vm.stopBroadcast();

        // 2. Create V3 pool for stock/USDC
        poolAddr = _createAndInitPool(stockAddr, priceUsd);
        console.log("V3 pool created for", symbol, "at:", poolAddr);

        // 3. Mint DID for the V3 pool and deployer
        vm.startBroadcast();
        if (_did.balanceOf(poolAddr) == 0) {
            _did.mintAdmin(poolAddr, 0, bytes32(0));
            console.log("Minted DID for V3 pool");
        }
        if (_did.balanceOf(msg.sender) == 0) {
            _did.mintAdmin(msg.sender, 0, bytes32(0));
            console.log("Minted DID for deployer");
        }

        // 4. Calculate USDC needed for two-sided liquidity at target price
        // For symmetric liquidity: usdcAmount = stockAmount * priceUsd / 1e12 (adjust decimals)
        uint256 usdcNeeded = (stockLiquidity * priceUsd) / 1e18; // stockLiquidity is 18 dec, priceUsd is 6 dec
        console.log("USDC needed for liquidity:", usdcNeeded);

        // Mint stock and USDC to liquidity helper
        _factory.forceMintStocks(
            symbol,
            address(_liquidityHelper),
            stockLiquidity
        );
        console.log("Minted stocks to liquidity helper:", stockLiquidity);

        // Mint USDC to helper (using mock's mint function)
        IERC20Mintable(address(_usdc)).mint(address(_liquidityHelper), usdcNeeded);
        console.log("Minted USDC to liquidity helper:", usdcNeeded);

        // 5. Register with router as AMM pool
        _router.setAMMPool(stockAddr, poolAddr);
        console.log("Registered AMM pool for", symbol);
        vm.stopBroadcast();

        // 6. Add two-sided liquidity around current price
        _addTwoSidedLiquidity(poolAddr, stockAddr);
    }

    struct TwoSidedParams {
        address poolAddr;
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function _addTwoSidedLiquidity(address poolAddr, address stockAddr) private {
        TwoSidedParams memory p = _calcTwoSidedParams(poolAddr, stockAddr);

        if (p.liquidity == 0) {
            console.log("  WARNING: Zero liquidity, skipping");
            return;
        }

        vm.startBroadcast();
        _executeTwoSidedAdd(p);
        _liquidityHelper.withdraw(stockAddr, msg.sender);
        _liquidityHelper.withdraw(address(_usdc), msg.sender);
        vm.stopBroadcast();
    }

    function _calcTwoSidedParams(
        address poolAddr,
        address stockAddr
    ) private view returns (TwoSidedParams memory p) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        (uint160 sqrtPriceX96, int24 currentTick, , , , , ) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        // Round current tick to valid tick
        int24 roundedTick = (currentTick / tickSpacing) * tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            roundedTick -= tickSpacing;
        }

        // Create a wide range around current price (200 tick spacings each side)
        p.tickLower = roundedTick - (200 * tickSpacing);
        p.tickUpper = roundedTick + (200 * tickSpacing);

        // Clamp to valid range
        if (p.tickLower < MIN_TICK) p.tickLower = MIN_TICK + tickSpacing;
        if (p.tickUpper > MAX_TICK) p.tickUpper = MAX_TICK - tickSpacing;

        // Determine token order
        p.poolAddr = poolAddr;
        p.token0 = stockAddr < address(_usdc) ? stockAddr : address(_usdc);
        p.token1 = stockAddr < address(_usdc) ? address(_usdc) : stockAddr;

        // Get balances and calculate liquidity
        uint256 balance0 = IERC20(p.token0).balanceOf(address(_liquidityHelper));
        uint256 balance1 = IERC20(p.token1).balanceOf(address(_liquidityHelper));

        console.log("Adding two-sided liquidity:");
        console.log("  token0 balance:", balance0);
        console.log("  token1 balance:", balance1);

        p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(p.tickLower),
            TickMath.getSqrtRatioAtTick(p.tickUpper),
            balance0,
            balance1
        );

        console.log("  Calculated liquidity:", uint256(p.liquidity));
    }

    function _executeTwoSidedAdd(TwoSidedParams memory p) private {
        try
            _liquidityHelper.addLiquidityTwoSided(
                p.poolAddr,
                p.token0,
                p.token1,
                p.tickLower,
                p.tickUpper,
                p.liquidity
            )
        returns (uint256 amount0, uint256 amount1) {
            console.log("  Added liquidity - amount0:", amount0, "amount1:", amount1);
        } catch Error(string memory reason) {
            console.log("  addLiquidity failed:", reason);
        } catch {
            console.log("  addLiquidity failed with unknown error");
        }
    }

    function _createAndInitPool(
        address stockToken,
        uint256 priceUsd
    ) private returns (address poolAddr) {
        address token0 = stockToken < address(_usdc)
            ? stockToken
            : address(_usdc);
        address token1 = stockToken < address(_usdc)
            ? address(_usdc)
            : stockToken;

        vm.startBroadcast();

        poolAddr = _v3Factory.getPool(token0, token1, FEE_TIER);
        if (poolAddr == address(0)) {
            poolAddr = _v3Factory.createPool(token0, token1, FEE_TIER);
        }

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        if (sqrtPriceX96 == 0) {
            uint160 initSqrtPriceX96 = _calcSqrtPrice(stockToken, priceUsd);
            console.log("Initializing pool with sqrtPriceX96:", uint256(initSqrtPriceX96));
            console.log("  Expected price USD:", priceUsd / 1e6);
            pool.initialize(initSqrtPriceX96);
        } else {
            console.log("Pool already initialized with sqrtPriceX96:", uint256(sqrtPriceX96));
        }

        vm.stopBroadcast();
    }

    function _calcSqrtPrice(
        address stockToken,
        uint256 priceUsd
    ) private view returns (uint160) {
        // Stock: 18 decimals, USDC: 6 decimals
        // V3 sqrtPriceX96 = sqrt(token1/token0) * 2^96
        // priceUsd is in 6 decimals (e.g., 10e6 for $10)
        bool stockIsToken0 = stockToken < address(_usdc);

        if (stockIsToken0) {
            // token0 = stock (18 dec), token1 = USDC (6 dec)
            // V3 raw price = USDC_raw / stock_raw = priceUsd / 1e18
            // sqrtPriceX96 = sqrt(priceUsd / 1e18) * 2^96
            //              = sqrt(priceUsd) / 1e9 * 2^96
            //              = sqrt(priceUsd) * 2^96 / 1e9
            uint256 sqrtPrice = Math.sqrt(priceUsd);
            return uint160((sqrtPrice << 96) / 1e9);
        } else {
            // token0 = USDC (6 dec), token1 = stock (18 dec)
            // V3 raw price = stock_raw / USDC_raw = 1e18 / priceUsd
            // sqrtPriceX96 = sqrt(1e18 / priceUsd) * 2^96
            //              = sqrt(1e18) / sqrt(priceUsd) * 2^96
            //              = 1e9 * 2^96 / sqrt(priceUsd)
            uint256 sqrtUsdc = Math.sqrt(priceUsd);
            return uint160((1e9 << 96) / sqrtUsdc);
        }
    }
}

/// @notice Interface for mintable tokens (USDCMock)
interface IERC20Mintable {
    function mint(address to, uint256 amount) external;
}
