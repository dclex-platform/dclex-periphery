// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IDclexSwapCallback} from "dclex-protocol/src/IDclexSwapCallback.sol";
import {
    ISwapRouter
} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {
    IQuoter
} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
//
/// @title DclexRouter
/// @notice Unified router for dual-DEX: DCLEX oracle pools (DCLEX) + Uniswap V3 V3 pools
/// @dev wDEL (wrapped DEL) is treated as a normal V3 token — wrapping/unwrapping is frontend responsibility
contract DclexRouter is Ownable, ReentrancyGuard, IDclexSwapCallback, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    error DclexRouter__InputTooHigh();
    error DclexRouter__OutputTooLow();
    error DclexRouter__DeadlinePassed();
    error DclexRouter__UnknownToken();
    error DclexRouter__NotDclexPool();
    error DclexRouter__NotV3Pool();
    error DclexRouter__InvalidCallback();
    error DclexRouter__NoLiquidity();
    error DclexRouter__StablecoinNotAllowed();

    enum PoolType {
        NONE,
        DCLEX,
        V3
    }

    struct DclexSwapCallbackData {
        address payer;
        bool payWithSwapExactOutput;
        address inputToken;
        uint256 maxInputAmount;
    }

    /// @notice Context passed through V3 pool.swap() -> uniswapV3SwapCallback
    /// @dev Carries who pays, which pool should be calling us, the user's
    ///      input-side slippage cap, and any oracle update a nested DclexPool
    ///      swap will need. Note: `msg.value` is 0 inside the V3 callback,
    ///      but the router still holds the user's original msg.value on its
    ///      own balance (V3 pools never take ETH), so nested DclexPool calls
    ///      forward `address(this).balance` to pay the oracle fee.
    struct V3SwapCallbackData {
        address payer;              // ultimate source of input tokens
        address inputToken;         // the token the user is spending
        address v3Token;           // the V3 token whose pool should be calling us
        uint256 maxInputAmount;     // user's slippage limit on the input side
        bytes[] oracleData;     // forwarded to DclexPool if input is DCLEX
    }
    // V3 infrastructure
    ISwapRouter public immutable v3SwapRouter;
    IQuoter public immutable v3Quoter;
    IERC20 public immutable stablecoin;

    // Pool type registry
    mapping(address => PoolType) public stockPoolType;
    mapping(address => DclexPool) public stockToDclexPool;
    mapping(address => address) public stockToV3Pool;
    mapping(address => uint24) public stockToFeeTier;

    // Legacy compatibility
    address[] private stockTokens;
    mapping(address => bool) private pools;

    event PoolSetForToken(
        address indexed token,
        address pool,
        PoolType poolType
    );

    error DclexRouter__ZeroAddress();
    error DclexRouter__InvalidFeeTier();
    error DclexRouter__NativeTransferFailed();

    constructor(
        ISwapRouter _v3SwapRouter,
        IQuoter _v3Quoter,
        IERC20 _stablecoin
    ) Ownable(msg.sender) {
        if (address(_v3SwapRouter) == address(0)) revert DclexRouter__ZeroAddress();
        if (address(_v3Quoter) == address(0)) revert DclexRouter__ZeroAddress();
        if (address(_stablecoin) == address(0)) revert DclexRouter__ZeroAddress();
        v3SwapRouter = _v3SwapRouter;
        v3Quoter = _v3Quoter;
        stablecoin = _stablecoin;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert DclexRouter__DeadlinePassed();
        }
        _;
    }

    modifier onlyDclexPool() {
        if (!pools[msg.sender]) {
            revert DclexRouter__NotDclexPool();
        }
        _;
    }

    modifier refundETH() {
        uint256 balanceBefore = address(this).balance - msg.value;
        _;
        uint256 balanceAfter = address(this).balance;
        if (balanceAfter > balanceBefore) {
            uint256 refund = balanceAfter - balanceBefore;
            (bool success, ) = msg.sender.call{value: refund}("");
            if (!success) revert DclexRouter__NativeTransferFailed();
        }
    }

    function _getFeeTier(address token) internal view returns (uint24) {
        uint24 feeTier = stockToFeeTier[token];
        if (feeTier == 0) revert DclexRouter__UnknownToken();
        return feeTier;
    }

    // ============ Pool Registry Functions ============

    function setDclexPool(address token, DclexPool pool) external onlyOwner {
        if (token == address(0)) revert DclexRouter__ZeroAddress();
        if (address(pool) == address(0)) {
            DclexPool oldPool = stockToDclexPool[token];
            pools[address(oldPool)] = false;
            stockPoolType[token] = PoolType.NONE;
            delete stockToDclexPool[token];
            _removeFromStockTokens(token);
            emit PoolSetForToken(token, address(0), PoolType.NONE);
        } else {
            // Clear old pool mapping if replacing
            DclexPool oldPool = stockToDclexPool[token];
            if (address(oldPool) != address(0)) {
                pools[address(oldPool)] = false;
            }
            pools[address(pool)] = true;
            stockPoolType[token] = PoolType.DCLEX;
            stockToDclexPool[token] = pool;
            _addToStockTokens(token);
            emit PoolSetForToken(token, address(pool), PoolType.DCLEX);
        }
    }


    function setV3Pool(
        address token,
        address v3Pool,
        uint24 feeTier
    ) external onlyOwner {
        if (token == address(0)) revert DclexRouter__ZeroAddress();
        if (v3Pool == address(0)) {
            stockPoolType[token] = PoolType.NONE;
            delete stockToV3Pool[token];
            delete stockToFeeTier[token];
            _removeFromStockTokens(token);
            emit PoolSetForToken(token, address(0), PoolType.NONE);
        } else {
            if (feeTier != 500 && feeTier != 3000 && feeTier != 10000) {
                revert DclexRouter__InvalidFeeTier();
            }
            stockPoolType[token] = PoolType.V3;
            stockToV3Pool[token] = v3Pool;
            stockToFeeTier[token] = feeTier;
            _addToStockTokens(token);
            emit PoolSetForToken(token, v3Pool, PoolType.V3);
        }
    }

    function stockTokenToPool(address token) external view returns (DclexPool) {
        return stockToDclexPool[token];
    }

    function getPoolType(address token) public view returns (PoolType) {
        return stockPoolType[token];
    }

    function allStockTokens() external view returns (address[] memory) {
        return stockTokens;
    }



    // ============ Single-Token Swap Functions (Buy/Sell) ============

    function buyExactOutput(
        address token,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        uint256 deadline,
        bytes[] calldata oracleData
    ) external payable nonReentrant checkDeadline(deadline) refundETH {
        uint256 inputAmount;
        PoolType poolType = stockPoolType[token];

        if (poolType == PoolType.DCLEX) {
            inputAmount = _getDclexPool(token).swapExactOutput{
                value: msg.value
            }(
                true,
                exactOutputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData({
                        payer: msg.sender,
                        payWithSwapExactOutput: false,
                        inputToken: address(0),
                        maxInputAmount: 0
                    })
                ),
                oracleData
            );
        } else if (poolType == PoolType.V3) {
            stablecoin.safeTransferFrom(msg.sender, address(this), maxInputAmount);
            inputAmount = _buyExactOutputOnV3(
                token,
                exactOutputAmount,
                msg.sender,
                maxInputAmount
            );
            uint256 refund = maxInputAmount - inputAmount;
            if (refund > 0) {
                stablecoin.safeTransfer(msg.sender, refund);
            }
        } else {
            revert DclexRouter__UnknownToken();
        }

        if (inputAmount > maxInputAmount) {
            revert DclexRouter__InputTooHigh();
        }
        
    }

    function sellExactOutput(
        address token,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        uint256 deadline,
        bytes[] calldata oracleData
    ) external payable nonReentrant checkDeadline(deadline) refundETH {
        uint256 inputAmount;
        PoolType poolType = stockPoolType[token];

        if (poolType == PoolType.DCLEX) {
            inputAmount = _getDclexPool(token).swapExactOutput{
                value: msg.value
            }(
                false,
                exactOutputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData({
                        payer: msg.sender,
                        payWithSwapExactOutput: false,
                        inputToken: address(0),
                        maxInputAmount: 0
                    })
                ),
                oracleData
            );
        } else if (poolType == PoolType.V3) {
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                maxInputAmount
            );
            inputAmount = _sellExactOutputOnV3(
                token,
                exactOutputAmount,
                msg.sender
            );
            uint256 refund = maxInputAmount - inputAmount;
            if (refund > 0) {
                IERC20(token).safeTransfer(msg.sender, refund);
            }
        } else {
            revert DclexRouter__UnknownToken();
        }

        if (inputAmount > maxInputAmount) {
            revert DclexRouter__InputTooHigh();
        }
    }

    function buyExactInput(
        address token,
        uint256 exactInputAmount,
        uint256 minOutputAmount,
        uint256 deadline,
        bytes[] calldata oracleData
    ) external payable nonReentrant checkDeadline(deadline) refundETH {
        uint256 outputAmount;
        PoolType poolType = stockPoolType[token];

        if (poolType == PoolType.DCLEX) {
            outputAmount = _getDclexPool(token).swapExactInput{
                value: msg.value
            }(
                true,
                exactInputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData({
                        payer: msg.sender,
                        payWithSwapExactOutput: false,
                        inputToken: address(0),
                        maxInputAmount: 0
                    })
                ),
                oracleData
            );
        } else if (poolType == PoolType.V3) {
            stablecoin.safeTransferFrom(msg.sender, address(this), exactInputAmount);
            outputAmount = _buyExactInputOnV3(
                token,
                exactInputAmount,
                msg.sender
            );
        } else {
            revert DclexRouter__UnknownToken();
        }

        if (outputAmount < minOutputAmount) {
            revert DclexRouter__OutputTooLow();
        }
    }

    function sellExactInput(
        address token,
        uint256 exactInputAmount,
        uint256 minOutputAmount,
        uint256 deadline,
        bytes[] calldata oracleData
    ) external payable nonReentrant checkDeadline(deadline) refundETH {
        uint256 outputAmount;
        PoolType poolType = stockPoolType[token];

        if (poolType == PoolType.DCLEX) {
            outputAmount = _getDclexPool(token).swapExactInput{
                value: msg.value
            }(
                false,
                exactInputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData({
                        payer: msg.sender,
                        payWithSwapExactOutput: false,
                        inputToken: address(0),
                        maxInputAmount: 0
                    })
                ),
                oracleData
            );
        } else if (poolType == PoolType.V3) {
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                exactInputAmount
            );
            outputAmount = _sellExactInputOnV3(token, exactInputAmount);
            stablecoin.safeTransfer(msg.sender, outputAmount);
        } else {
            revert DclexRouter__UnknownToken();
        }

        if (outputAmount < minOutputAmount) {
            revert DclexRouter__OutputTooLow();
        }
    }

    // ============ Cross-Pool Swap Functions ============

    function swapExactInput(
        address inputToken,
        address outputToken,
        uint256 exactInputAmount,
        uint256 minOutputAmount,
        uint256 deadline,
        bytes[] calldata oracleData
    ) external payable nonReentrant checkDeadline(deadline) refundETH {
        // stablecoin is the internal routing hop, never a user-facing leg here.
        // Callers wanting stablecoin in/out must use buy/sell*Exact* instead.
        if (
            inputToken == address(stablecoin) || outputToken == address(stablecoin)
        ) {
            revert DclexRouter__StablecoinNotAllowed();
        }

        uint256 stablecoinAmount;
        uint256 outputAmount;

        // Step 1: Input -> stablecoin
        PoolType inputType = stockPoolType[inputToken];
        if (inputType == PoolType.DCLEX) {
            bytes memory callbackData = abi.encode(
                DclexSwapCallbackData({
                    payer: msg.sender,
                    payWithSwapExactOutput: false,
                    inputToken: address(0),
                    maxInputAmount: 0
                })
            );
            stablecoinAmount = stockToDclexPool[inputToken].swapExactInput{
                value: msg.value
            }(
                false,
                exactInputAmount,
                address(this),
                callbackData,
                oracleData
            );
        } else if (inputType == PoolType.V3) {
            IERC20(inputToken).safeTransferFrom(
                msg.sender,
                address(this),
                exactInputAmount
            );
            stablecoinAmount = _sellExactInputOnV3(
                inputToken,
                exactInputAmount
            );
        } else {
            revert DclexRouter__UnknownToken();
        }

        // Step 2: stablecoin -> Output
        PoolType outputType = stockPoolType[outputToken];
        if (outputType == PoolType.DCLEX) {
            bytes memory callbackData = abi.encode(
                DclexSwapCallbackData({
                    payer: address(this),
                    payWithSwapExactOutput: false,
                    inputToken: address(0),
                    maxInputAmount: 0
                })
            );
            // If step 1 was DCLEX, oracleData + msg.value were already
            // consumed by the input pool (the shared oracle is now fresh, so
            // the output pool reads it without needing its own update).
            // If step 1 was V3, no oracle update has happened yet — forward
            // both here so the output pool can run updatePriceFeeds itself.
            bool outputNeedsUpdate = inputType == PoolType.V3;
            outputAmount = stockToDclexPool[outputToken].swapExactInput{
                value: outputNeedsUpdate ? msg.value : 0
            }(
                true,
                stablecoinAmount,
                msg.sender,
                callbackData,
                outputNeedsUpdate ? oracleData : new bytes[](0)
            );
        } else if (outputType == PoolType.V3) {
            outputAmount = _buyExactInputOnV3(
                outputToken,
                stablecoinAmount,
                msg.sender
            );
        } else {
            revert DclexRouter__UnknownToken();
        }

        if (outputAmount < minOutputAmount) {
            revert DclexRouter__OutputTooLow();
        }
    }

function swapExactOutput(
    address inputToken,
    address outputToken,
    uint256 exactOutputAmount,
    uint256 maxInputAmount,
    uint256 deadline,
    bytes[] calldata oracleData
) external payable nonReentrant checkDeadline(deadline) refundETH {
    // Callers wanting stablecoin in/out must use buy/sell*Exact* instead.
    if (
        inputToken == address(stablecoin) || outputToken == address(stablecoin)
    ) {
        revert DclexRouter__StablecoinNotAllowed();
    }

    PoolType outputType = stockPoolType[outputToken];

    if (outputType == PoolType.DCLEX) {
        _executeDclexExactOutput(
            inputToken,
            outputToken,
            exactOutputAmount,
            maxInputAmount,
            msg.sender,
            oracleData
        );
    } else if (outputType == PoolType.V3) {
        _executeV3ExactOutput(
            inputToken,
            outputToken,
            exactOutputAmount,
            maxInputAmount,
            msg.sender,
            oracleData
        );
    } else {
        revert DclexRouter__UnknownToken();
    }
}

    // ============ DCLEX Callback Data Helper ============

    
    /// @notice Initiates a swap where the output is a DCLEX stock token
    /// @dev Calls DclexPool.swapExactOutput. Payment (stablecoin) is produced inside
    ///      dclexSwapCallback, which dispatches based on the user's input type.
    ///      The output token is sent directly from DclexPool to the user.
    function _executeDclexExactOutput(
        address inputToken,
        address outputToken,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        address payer,
        bytes[] calldata oracleData
    ) private {
        // Validate input token
        PoolType inputType = stockPoolType[inputToken];
        if (inputType == PoolType.NONE && inputToken != address(stablecoin)) {
            revert DclexRouter__UnknownToken();
        }

        // Build the callback context. payWithSwapExactOutput=true tells the
        // DCLEX callback that it needs to PRODUCE the input rather than just
        // pulling it (because the input isn't stablecoin, or even if it is stablecoin the
        // existing callback handles that case).
        bytes memory callbackData = abi.encode(
            DclexSwapCallbackData({
                payer: payer,
                payWithSwapExactOutput: true,
                inputToken: inputToken,
                maxInputAmount: maxInputAmount
            })
        );

        // Initiate the DclexPool exact-output swap. DclexPool will:
        //   1. Send exactOutputAmount of outputToken to `payer`
        //   2. Call dclexSwapCallback on us, demanding stablecoin
        //   3. Complete only after we've delivered stablecoin
        stockToDclexPool[outputToken].swapExactOutput{value: msg.value}(
            true,                       // isBuy = true (we provide stablecoin, get stock)
            exactOutputAmount,
            payer,                      // user receives the stock directly
            callbackData,
            oracleData
        );
        // Slippage on the input leg is enforced inside dclexSwapCallback
        // via maxInputAmount embedded in callbackData.
    }

    /// @notice Called by a DclexPool mid-swap to collect payment
    /// @dev Handles three modes:
    ///      - payWithSwapExactOutput=false, payer=router: router transfers from its own balance
    ///      - payWithSwapExactOutput=false, payer=user:   pull from user via transferFrom
    ///      - payWithSwapExactOutput=true:                produce payment by swapping inputToken
    function dclexSwapCallback(
        address token,
        uint256 amount,
        bytes calldata callbackData
    ) external onlyDclexPool {
        DclexSwapCallbackData memory data = abi.decode(
            callbackData,
            (DclexSwapCallbackData)
        );

        if (data.payWithSwapExactOutput) {
            // We need to produce `amount` of `token` (always stablecoin in this flow,
            // since DCLEX pools only ever ask for stablecoin during a buy).
            // Dispatch on the input token type.
            uint256 inputUsed = _produceStablecoinForDclexPayment(
                token,                  // should be stablecoin
                amount,
                msg.sender,             // stablecoin recipient = the calling DclexPool
                data
            );

            // Slippage check on the cumulative input consumed
            if (inputUsed > data.maxInputAmount) {
                revert DclexRouter__InputTooHigh();
            }
        } else {
            // Simple mode: payer is either the router itself (already holding tokens)
            // or the user (pull via transferFrom).
            if (data.payer == address(this)) {
                IERC20(token).safeTransfer(msg.sender, amount);
            } else {
                IERC20(token).safeTransferFrom(data.payer, msg.sender, amount);
            }
        }
    }

    /// @notice Acquire `stablecoinAmount` of stablecoin and send it to `dclexPool`
    /// @dev Mirror of _produceStablecoinForV3Payment but called from inside
    ///      dclexSwapCallback. The recipient is always the DclexPool that
    ///      initiated the callback (passed as `dclexPool`).
    function _produceStablecoinForDclexPayment(
        address tokenOwed,
        uint256 stablecoinAmount,
        address dclexPool,
        DclexSwapCallbackData memory data
    ) private returns (uint256 inputUsed) {
        // Sanity: DclexPools should only ever ask us for stablecoin during a buy
        if (tokenOwed != address(stablecoin)) {
            revert DclexRouter__InvalidCallback();
        }

        PoolType inputType = stockPoolType[data.inputToken];

        // --- Case 1: input is another DCLEX stock ---
        // Sell input stock for stablecoin via its DclexPool. The inner DclexPool
        // calls dclexSwapCallback again — this time with payWithSwapExactOutput=false
        // and payer=user, so it'll just pull the input stock from the user.
        if (inputType == PoolType.DCLEX) {
            inputUsed = stockToDclexPool[data.inputToken].swapExactOutput(
                false,                  // isBuy = false (selling stock for stablecoin)
                stablecoinAmount,
                dclexPool,              // stablecoin recipient = outer DclexPool
                abi.encode(
                    DclexSwapCallbackData({
                        payer: data.payer,          // payer=user
                        payWithSwapExactOutput: false,
                        inputToken: address(0),
                        maxInputAmount: 0
                    })
                ),
                new bytes[](0)          // no oracle update (both price must be updated in the first call)
            );
            return inputUsed;
        }

        // --- Case 2: input is an V3 token ---
        // Direct V3 pool call. The V3 callback's case (a) will pull the input
        // token from the user. stablecoin goes directly to the outer DclexPool.
        if (inputType == PoolType.V3) {
            address v3PoolAddr = stockToV3Pool[data.inputToken];
            if (v3PoolAddr == address(0)) revert DclexRouter__UnknownToken();

            inputUsed = _v3NestedExactOutput(
                IUniswapV3Pool(v3PoolAddr),
                data.inputToken,
                address(stablecoin),
                stablecoinAmount,
                dclexPool,              // stablecoin recipient = outer DclexPool
                // Synthesize a V3 callback context. Setting v3Token=inputToken
                // means the V3 callback's case (a) will fire and pull from user
                // — no nested DclexPool runs here, so oracleData is unused.
                V3SwapCallbackData({
                    payer: data.payer,
                    inputToken: data.inputToken,
                    v3Token: data.inputToken,
                    maxInputAmount: data.maxInputAmount,
                    oracleData: new bytes[](0)
                })
            );
            return inputUsed;
        }

        revert DclexRouter__UnknownToken();
    }


    // ============ V3 Callback Data Helper ============


    /// @notice Initiates an exact-output swap where the output comes from a V3 pool
    /// @dev The payment (stablecoin) is produced inside uniswapV3SwapCallback.
    ///      The user receives the output directly from the V3 pool.
    function _executeV3ExactOutput(
        address inputToken,
        address outputToken,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        address payer,
        bytes[] calldata oracleData
    ) private {
        // Validate input token is registered
        PoolType inputType = stockPoolType[inputToken];
        if (inputType == PoolType.NONE && inputToken != address(stablecoin)) {
            revert DclexRouter__UnknownToken();
        }

        address v3PoolAddr = stockToV3Pool[outputToken];
        if (v3PoolAddr == address(0)) revert DclexRouter__UnknownToken();
        IUniswapV3Pool v3Pool = IUniswapV3Pool(v3PoolAddr);

        // V3 convention: zeroForOne=true means selling token0 for token1.
        // We're selling stablecoin for the output token.
        bool zeroForOne = address(stablecoin) < outputToken;

        // Exact output is signaled by negative amountSpecified.
        int256 amountSpecified = -int256(exactOutputAmount);

        // No price limit at the pool level; we enforce slippage via the input
        // amount check inside the callback.
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? TickMath.MIN_SQRT_RATIO + 1
            : TickMath.MAX_SQRT_RATIO - 1;

        // Build the context the V3 callback will need
        V3SwapCallbackData memory ctx = V3SwapCallbackData({
            payer: payer,
            inputToken: inputToken,
            v3Token: outputToken,
            maxInputAmount: maxInputAmount,
            oracleData: oracleData
        });

        // Kick off the swap. V3 will:
        //   1. Send exactOutputAmount of outputToken to `payer`
        //   2. Call uniswapV3SwapCallback on us demanding stablecoin
        //   3. Complete only if we paid
        (int256 amount0, int256 amount1) = v3Pool.swap(
            payer,                     // output recipient = user
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            abi.encode(ctx)
        );

        // Sanity check: we should have received the full requested output.
        // V3 can return slightly more than requested due to tick rounding,
        // but not less.
        int256 receivedOutput = zeroForOne ? -amount1 : -amount0;
        if (receivedOutput < int256(exactOutputAmount)) {
            revert DclexRouter__NoLiquidity();
        }
    }

    /// @notice Called by a V3 pool mid-swap to collect payment
    /// @param amount0Delta  token0 owed (positive) or received (negative)
    /// @param amount1Delta  token1 owed (positive) or received (negative)
    /// @param data          abi-encoded V3SwapCallbackData

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        V3SwapCallbackData memory ctx = abi.decode(data, (V3SwapCallbackData));

        if (msg.sender != stockToV3Pool[ctx.v3Token]) {
            revert DclexRouter__NotV3Pool();
        }

        // Exactly one delta must be strictly positive (the amount we owe).
        if (amount0Delta <= 0 && amount1Delta <= 0) {
            revert DclexRouter__InvalidCallback();
        }

        // --- Identify token and amount owed ---
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        address tokenOwed;
        uint256 amountOwed;
        if (amount0Delta > 0) {
            tokenOwed = pool.token0();
            amountOwed = uint256(amount0Delta);
        } else {
            tokenOwed = pool.token1();
            amountOwed = uint256(amount1Delta);
        }

        // --- Pay the V3 pool ---
        // Three mutually exclusive cases based on what we owe:
        //
        //   (a) The token owed IS the user's input token.
        //       → Pull directly from the user.
        //       → This happens when we're deep inside a nested callback chain and the
        //         innermost pool is asking for the user's original input.
        //
        //   (b) The token owed is stablecoin, and the user's input is a token on DCLEX.
        //       → Trigger a DCLEX swap to produce stablecoin, sent directly to `pool`.
        //       → The DclexPool will call dclexSwapCallback, which will pull
        //         the DCLEX token from the user.
        //
        //   (c) The token owed is stablecoin, and the user's input is another token on UniV3.
        //       → Trigger a V3 swap to produce stablecoin, sent directly to `pool`.
        //         This nests another uniswapV3SwapCallback,
        //         which will resolve to case (a) at its innermost level.

        if (tokenOwed == ctx.inputToken) {
            // Case (a): direct payment from user.
            //
            // Legitimately reached only by the nested V3→V3 flow — the
            // innermost input pool asks for the user's input token on V3.

            if (tokenOwed == address(stablecoin)) {
                revert DclexRouter__StablecoinNotAllowed();
            }
            if (amountOwed > ctx.maxInputAmount) {
                revert DclexRouter__InputTooHigh();
            }
            IERC20(tokenOwed).safeTransferFrom(ctx.payer, msg.sender, amountOwed);
        } else if (tokenOwed == address(stablecoin)) {
            // Cases (b) and (c): produce stablecoin by swapping the input token
            _produceStablecoinForV3Payment(ctx, amountOwed, msg.sender);
        } else {
            revert DclexRouter__InvalidCallback();
        }
    }

    /// @notice stablecoin-production helper for the V3 callback
    /// @dev Acquire `stablecoinAmount` of stablecoin and send it to `recipient`
    /// @dev `recipient` is always the V3 pool that invoked uniswapV3SwapCallback.
    function _produceStablecoinForV3Payment(
        V3SwapCallbackData memory ctx,
        uint256 stablecoinAmount,
        address recipient
    ) private {
        PoolType inputType = stockPoolType[ctx.inputToken];
        uint256 inputUsed;

        if (inputType == PoolType.DCLEX) {
            // --- Case (b): input token is on DCLEX ---
            // Call the input DclexPool to sell the stock for stablecoin. Stablecoins go
            // directly to `recipient` (the outer V3 pool). DclexPool will
            // then call dclexSwapCallback on us; that callback sees
            // payWithSwapExactOutput=false and pulls DCLEX tokens from
            // ctx.payer via safeTransferFrom.
            //
            // `msg.value` is 0 inside this V3 callback, but the user's
            // original msg.value is still on the router's balance because
            // V3 pools never take ETH. Forwarding `address(this).balance`
            // gives the nested DclexPool what it needs to pay the oracle fee
            // inside its own updatePriceFeeds call.
            inputUsed = stockToDclexPool[ctx.inputToken].swapExactOutput{
                value: address(this).balance
            }(
                false,                  // isBuy = false (selling stock for stablecoin)
                stablecoinAmount,
                recipient,              // stablecoin recipient = outer V3 pool
                abi.encode(
                    DclexSwapCallbackData({
                        payer: ctx.payer,
                        payWithSwapExactOutput: false,
                        inputToken: address(0),
                        maxInputAmount: 0
                    })
                ),
                ctx.oracleData
            );
        } else if (inputType == PoolType.V3) {
            // --- Case (c): input token is on V3 ---
            // Nested V3 exact-output swap. Another uniswapV3SwapCallback will
            // fire on the input pool; it resolves to case (a) because at that
            // point the token owed will be ctx.inputToken itself.
            address inputPoolAddr = stockToV3Pool[ctx.inputToken];
            if (inputPoolAddr == address(0)) revert DclexRouter__UnknownToken();

            // Build the nested callback context.
            // Setting v3Token == inputToken makes the nested V3 callback
            // authenticate against the input pool and hit case (a) — pull
            // inputToken directly from the user.
            V3SwapCallbackData memory nestedCtx = V3SwapCallbackData({
                payer: ctx.payer,
                inputToken: ctx.inputToken,
                v3Token: ctx.inputToken,
                maxInputAmount: ctx.maxInputAmount,
                oracleData: ctx.oracleData
            });

            inputUsed = _v3NestedExactOutput(
                IUniswapV3Pool(inputPoolAddr),
                ctx.inputToken,
                address(stablecoin),
                stablecoinAmount,
                recipient,
                nestedCtx
            );
        } else {
            revert DclexRouter__UnknownToken();
        }

        if (inputUsed > ctx.maxInputAmount) {
            revert DclexRouter__InputTooHigh();
        }
    }

    // ============================================================
    // Low-level nested V3 swap (for case c)
    // ============================================================
    
    // Single implementation. Caller is responsible for building the
    // V3SwapCallbackData context. This keeps the function's job narrow:
    // "execute a V3 exact-output swap and tell me how much input it used."
    // ============================================================

    /// @notice Execute a V3 exact-output swap on `pool`
    /// @param pool             The V3 pool to swap on
    /// @param inputToken       Token being spent (used for zeroForOne determination)
    /// @param outputToken      Token being received (usually stablecoin, but parameterized)
    /// @param outputAmount     Exact amount of outputToken to receive
    /// @param outputRecipient  Where the output token goes
    /// @param ctx              Callback context; passed verbatim into the V3 callback
    /// @return inputUsed       Amount of inputToken consumed by the swap
    /// @dev The function is agnostic to what the V3 callback does with `ctx`.
    ///      The caller decides whether the callback should hit case (a) (direct pull)
    ///      by setting ctx.v3Token == ctx.inputToken, or produce payment some other way.
    function _v3NestedExactOutput(
        IUniswapV3Pool pool,
        address inputToken,
        address outputToken,
        uint256 outputAmount,
        address outputRecipient,
        V3SwapCallbackData memory ctx
    ) private returns (uint256 inputUsed) {
        // V3 convention: zeroForOne=true means selling token0 for token1.
        // Lower address is token0, so we're token0 iff inputToken < outputToken.
        bool zeroForOne = inputToken < outputToken;

        // Exact output is signaled by a negative amountSpecified
        int256 amountSpecified = -int256(outputAmount);

        // No price limit; slippage is enforced by the callback via ctx.maxInputAmount.
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? TickMath.MIN_SQRT_RATIO + 1
            : TickMath.MAX_SQRT_RATIO - 1;

        (int256 amount0, int256 amount1) = pool.swap(
            outputRecipient,
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            abi.encode(ctx)
        );

        // The positive delta is what we paid in (inputToken).
        // If zeroForOne, inputToken is token0, so amount0 is positive.
        inputUsed = zeroForOne ? uint256(amount0) : uint256(amount1);
    }


    // ============ V3 Swap Helpers ============

    function _sellExactInputOnV3(
        address token,
        uint256 amount
    ) private returns (uint256) {
        IERC20(token).safeIncreaseAllowance(address(v3SwapRouter), amount);
        return
            v3SwapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: address(stablecoin),
                    fee: _getFeeTier(token),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _buyExactInputOnV3(
        address token,
        uint256 stablecoinAmount,
        address recipient
    ) private returns (uint256) {
        stablecoin.safeIncreaseAllowance(address(v3SwapRouter), stablecoinAmount);
        return
            v3SwapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(stablecoin),
                    tokenOut: token,
                    fee: _getFeeTier(token),
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: stablecoinAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _sellExactOutputOnV3(
        address token,
        uint256 stablecoinAmount,
        address recipient
    ) private returns (uint256) {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeIncreaseAllowance(
            address(v3SwapRouter),
            tokenBalance
        );
        return
            v3SwapRouter.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: token,
                    tokenOut: address(stablecoin),
                    fee: _getFeeTier(token),
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: stablecoinAmount,
                    amountInMaximum: tokenBalance,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _buyExactOutputOnV3(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 maxStablecoinAmount
    ) private returns (uint256) {
        stablecoin.safeIncreaseAllowance(address(v3SwapRouter), maxStablecoinAmount);
        return
            v3SwapRouter.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: address(stablecoin),
                    tokenOut: token,
                    fee: _getFeeTier(token),
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: tokenAmount,
                    amountInMaximum: maxStablecoinAmount,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    // ============ Cross-Pool ExactOutput Helper ============



    // ============ Internal Helpers ============

    function _updatePriceFeeds(
        address token,
        bytes[] calldata oracleData
    ) private {
        PoolType poolType = stockPoolType[token];
        if (poolType == PoolType.DCLEX && oracleData.length > 0) {
            stockToDclexPool[token].updatePriceFeeds{value: msg.value}(
                oracleData
            );
        }
    }

    function _getDclexPool(address token) private view returns (DclexPool) {
        if (stockPoolType[token] != PoolType.DCLEX) {
            revert DclexRouter__UnknownToken();
        }
        DclexPool pool = stockToDclexPool[token];
        if (address(pool) == address(0)) {
            revert DclexRouter__UnknownToken();
        }
        return pool;
    }

    function _addToStockTokens(address token) private {
        for (uint256 i = 0; i < stockTokens.length; ++i) {
            if (stockTokens[i] == token) {
                return;
            }
        }
        stockTokens.push(token);
    }

    function _removeFromStockTokens(address token) private {
        for (uint256 i = 0; i < stockTokens.length; ++i) {
            if (stockTokens[i] == token) {
                stockTokens[i] = stockTokens[stockTokens.length - 1];
                stockTokens.pop();
                return;
            }
        }
    }
}
