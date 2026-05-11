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
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @title DclexRouter
/// @notice Unified router for dual-DEX: DCLEX oracle pools + Uniswap V3 pools.
/// @dev wDEL is treated as a normal V3 token — wrapping/unwrapping is frontend responsibility.
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

    /// @dev `oracleFeeBudget` snapshots msg.value at the entry point so a
    ///      nested DclexPool call inside the V3 callback (where msg.value=0)
    ///      can still pay the oracle fee without sweeping unrelated ETH.
    struct V3SwapCallbackData {
        address payer;
        address inputToken;
        address v3Token;
        uint256 maxInputAmount;
        uint256 oracleFeeBudget;
        bytes[] priceUpdateData;
    }
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
    error DclexRouter__PoolMismatch();

    constructor(IERC20 _stablecoin) Ownable(msg.sender) {
        if (address(_stablecoin) == address(0)) revert DclexRouter__ZeroAddress();
        stablecoin = _stablecoin;
    }

    /// @notice Recover ETH accidentally sent to the router. The router only
    ///         holds ETH transiently (in-flight oracle fee for a single
    ///         swap), so any persistent balance is misdirected and would be
    ///         otherwise unreachable.
    function withdrawETH(address payable receiver) external onlyOwner {
        if (receiver == address(0)) revert DclexRouter__ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = receiver.call{value: bal}("");
        if (!ok) revert DclexRouter__NativeTransferFailed();
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

    // ============ Pool Registry Functions ============

    // Wipes whichever pool-type mapping was previously active for `token`
    // so the registry can never end up with stale entries from a prior type.
    function _clearStockRegistry(address token) private {
        PoolType prev = stockPoolType[token];
        if (prev == PoolType.DCLEX) {
            address oldDclex = address(stockToDclexPool[token]);
            if (oldDclex != address(0)) pools[oldDclex] = false;
            delete stockToDclexPool[token];
        } else if (prev == PoolType.V3) {
            delete stockToV3Pool[token];
            delete stockToFeeTier[token];
        }
        stockPoolType[token] = PoolType.NONE;
    }

    function setDclexPool(address token, DclexPool pool) external onlyOwner {
        if (token == address(0)) revert DclexRouter__ZeroAddress();
        _clearStockRegistry(token);
        if (address(pool) == address(0)) {
            _removeFromStockTokens(token);
            emit PoolSetForToken(token, address(0), PoolType.NONE);
        } else {
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
        _clearStockRegistry(token);
        if (v3Pool == address(0)) {
            _removeFromStockTokens(token);
            emit PoolSetForToken(token, address(0), PoolType.NONE);
        } else {
            if (feeTier != 500 && feeTier != 3000 && feeTier != 10000) {
                revert DclexRouter__InvalidFeeTier();
            }
            address t0 = IUniswapV3Pool(v3Pool).token0();
            address t1 = IUniswapV3Pool(v3Pool).token1();
            bool pairOk = (t0 == address(stablecoin) && t1 == token) ||
                (t0 == token && t1 == address(stablecoin));
            if (!pairOk) revert DclexRouter__PoolMismatch();
            if (IUniswapV3Pool(v3Pool).fee() != feeTier) {
                revert DclexRouter__PoolMismatch();
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
        bytes[] calldata priceUpdateData
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
                priceUpdateData
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
        bytes[] calldata priceUpdateData
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
                priceUpdateData
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
                msg.sender,
                maxInputAmount
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
        bytes[] calldata priceUpdateData
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
                priceUpdateData
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
        bytes[] calldata priceUpdateData
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
                priceUpdateData
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
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant checkDeadline(deadline) refundETH {
        if (
            inputToken == address(stablecoin) || outputToken == address(stablecoin)
        ) {
            revert DclexRouter__StablecoinNotAllowed();
        }

        PoolType inputType = stockPoolType[inputToken];
        uint256 stablecoinAmount = _swapInputLegToStablecoin(
            inputToken,
            inputType,
            exactInputAmount,
            priceUpdateData
        );

        uint256 outputAmount = _swapStablecoinLegToOutput(
            outputToken,
            stablecoinAmount,
            inputType,
            priceUpdateData
        );

        if (outputAmount < minOutputAmount) {
            revert DclexRouter__OutputTooLow();
        }
    }

    function _swapInputLegToStablecoin(
        address inputToken,
        PoolType inputType,
        uint256 exactInputAmount,
        bytes[] calldata priceUpdateData
    ) private returns (uint256 stablecoinAmount) {
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
            }(false, exactInputAmount, address(this), callbackData, priceUpdateData);
        } else if (inputType == PoolType.V3) {
            IERC20(inputToken).safeTransferFrom(msg.sender, address(this), exactInputAmount);
            stablecoinAmount = _sellExactInputOnV3(inputToken, exactInputAmount);
        } else {
            revert DclexRouter__UnknownToken();
        }
    }

    function _swapStablecoinLegToOutput(
        address outputToken,
        uint256 stablecoinAmount,
        PoolType inputType,
        bytes[] calldata priceUpdateData
    ) private returns (uint256 outputAmount) {
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
            // Step 1 DCLEX already consumed oracle update; step 1 V3 still needs it.
            bool needsUpdate = inputType == PoolType.V3;
            outputAmount = stockToDclexPool[outputToken].swapExactInput{
                value: needsUpdate ? msg.value : 0
            }(
                true,
                stablecoinAmount,
                msg.sender,
                callbackData,
                needsUpdate ? priceUpdateData : new bytes[](0)
            );
        } else if (outputType == PoolType.V3) {
            outputAmount = _buyExactInputOnV3(outputToken, stablecoinAmount, msg.sender);
        } else {
            revert DclexRouter__UnknownToken();
        }
    }

    function swapExactOutput(
        address inputToken,
        address outputToken,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        uint256 deadline,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant checkDeadline(deadline) refundETH {
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
                priceUpdateData
            );
        } else if (outputType == PoolType.V3) {
            _executeV3ExactOutput(
                inputToken,
                outputToken,
                exactOutputAmount,
                maxInputAmount,
                msg.sender,
                priceUpdateData
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
        bytes[] calldata priceUpdateData
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
            priceUpdateData
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
    ) external override onlyDclexPool {
        DclexSwapCallbackData memory data = abi.decode(
            callbackData,
            (DclexSwapCallbackData)
        );

        if (data.payWithSwapExactOutput) {
            // Slippage is enforced inside _produceStablecoinForDclexPayment
            // (case 1 inline; case 2 via the nested V3 callback).
            _produceStablecoinForDclexPayment(token, amount, msg.sender, data);
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
        // The inner DclexPool's callback just pulls input stock from the user
        // without checking slippage — enforce maxInput here.
        if (inputType == PoolType.DCLEX) {
            inputUsed = stockToDclexPool[data.inputToken].swapExactOutput(
                false,
                stablecoinAmount,
                dclexPool,
                abi.encode(
                    DclexSwapCallbackData({
                        payer: data.payer,
                        payWithSwapExactOutput: false,
                        inputToken: address(0),
                        maxInputAmount: 0
                    })
                ),
                new bytes[](0)
            );
            if (inputUsed > data.maxInputAmount) revert DclexRouter__InputTooHigh();
            return inputUsed;
        }

        // --- Case 2: input is a V3 token ---
        // The nested V3 callback hits case (a), which enforces slippage
        // against ctx.maxInputAmount — no extra check needed here.
        if (inputType == PoolType.V3) {
            (inputUsed, ) = _v3Swap(
                -int256(stablecoinAmount),
                data.inputToken,
                dclexPool,
                V3SwapCallbackData({
                    payer: data.payer,
                    inputToken: data.inputToken,
                    v3Token: data.inputToken,
                    maxInputAmount: data.maxInputAmount,
                    oracleFeeBudget: 0,
                    priceUpdateData: new bytes[](0)
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
        bytes[] calldata priceUpdateData
    ) private {
        // Validate input token is registered
        PoolType inputType = stockPoolType[inputToken];
        if (inputType == PoolType.NONE && inputToken != address(stablecoin)) {
            revert DclexRouter__UnknownToken();
        }

        (, uint256 outAmount) = _v3Swap(
            -int256(exactOutputAmount),
            address(stablecoin),
            payer,
            V3SwapCallbackData({
                payer: payer,
                inputToken: inputToken,
                v3Token: outputToken,
                maxInputAmount: maxInputAmount,
                oracleFeeBudget: msg.value,
                priceUpdateData: priceUpdateData
            })
        );
        // Defensive: V3 settles exact-output swaps at the requested amount,
        // but guard against a malformed pool returning less.
        if (outAmount < exactOutputAmount) revert DclexRouter__NoLiquidity();
    }

    /// @notice Called by a V3 pool mid-swap to collect payment
    /// @param amount0Delta  token0 owed (positive) or received (negative)
    /// @param amount1Delta  token1 owed (positive) or received (negative)
    /// @param data          abi-encoded V3SwapCallbackData

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        V3SwapCallbackData memory ctx = abi.decode(data, (V3SwapCallbackData));

        if (msg.sender != stockToV3Pool[ctx.v3Token]) {
            revert DclexRouter__NotV3Pool();
        }

        // At least one delta must be strictly positive — that's the side we owe.
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
            // Case (a): pay directly with ctx.inputToken. Router holds the
            // tokens for single-leg flows (entry-points pull from user up
            // front); cross-pool flows leave the user as payer.
            if (amountOwed > ctx.maxInputAmount) {
                revert DclexRouter__InputTooHigh();
            }
            if (ctx.payer == address(this)) {
                IERC20(tokenOwed).safeTransfer(msg.sender, amountOwed);
            } else {
                IERC20(tokenOwed).safeTransferFrom(ctx.payer, msg.sender, amountOwed);
            }
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

        // --- Case (b): input token is on DCLEX ---
        // The inner DclexPool's callback pulls input stock from the user
        // without slippage validation, so enforce maxInput here.
        if (inputType == PoolType.DCLEX) {
            uint256 inputUsed = stockToDclexPool[ctx.inputToken].swapExactOutput{
                value: ctx.oracleFeeBudget
            }(
                false,
                stablecoinAmount,
                recipient,
                abi.encode(
                    DclexSwapCallbackData({
                        payer: ctx.payer,
                        payWithSwapExactOutput: false,
                        inputToken: address(0),
                        maxInputAmount: 0
                    })
                ),
                ctx.priceUpdateData
            );
            if (inputUsed > ctx.maxInputAmount) revert DclexRouter__InputTooHigh();
            return;
        }

        // --- Case (c): input token is on V3 ---
        // The nested V3 callback hits case (a) and enforces slippage against
        // ctx.maxInputAmount itself.
        if (inputType == PoolType.V3) {
            _v3Swap(
                -int256(stablecoinAmount),
                ctx.inputToken,
                recipient,
                V3SwapCallbackData({
                    payer: ctx.payer,
                    inputToken: ctx.inputToken,
                    v3Token: ctx.inputToken,
                    maxInputAmount: ctx.maxInputAmount,
                    oracleFeeBudget: 0,
                    priceUpdateData: ctx.priceUpdateData
                })
            );
            return;
        }

        revert DclexRouter__UnknownToken();
    }

    // ============ V3 Swap Helpers ============
    //
    // All four call `pool.swap()` directly (rather than Uniswap's periphery
    // `SwapRouter.exact*Single`) so we don't depend on the hardcoded
    // `POOL_INIT_CODE_HASH` literal in `PoolAddress.sol` matching the
    // bytecode our Solc pipeline produces. The router holds the input
    // tokens for these helpers (entry-points pull from user up front),
    // so `payer = address(this)` and the callback uses `safeTransfer`.

    /// @dev `ctx.v3Token` picks the pool; the OTHER token of the pool is
    ///      always stablecoin (we never run a V3↔V3 swap on a single pool).
    ///      `tokenIn` says which side of that pair the caller is paying with.
    function _v3Swap(
        int256 amountSpecified, // positive = exact input; negative = exact output
        address tokenIn,
        address recipient,
        V3SwapCallbackData memory ctx
    ) private returns (uint256 amountIn, uint256 amountOut) {
        address poolAddr = stockToV3Pool[ctx.v3Token];
        if (poolAddr == address(0)) revert DclexRouter__UnknownToken();
        address tokenOut = tokenIn == address(stablecoin) ? ctx.v3Token : address(stablecoin);
        bool zeroForOne = tokenIn < tokenOut;
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? TickMath.MIN_SQRT_RATIO + 1
            : TickMath.MAX_SQRT_RATIO - 1;
        (int256 amount0, int256 amount1) = IUniswapV3Pool(poolAddr).swap(
            recipient,
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            abi.encode(ctx)
        );
        if (zeroForOne) {
            amountIn = uint256(amount0);
            amountOut = uint256(-amount1);
        } else {
            amountIn = uint256(amount1);
            amountOut = uint256(-amount0);
        }
    }

    function _routerCtxForV3(
        address stockToken,
        address tokenIn,
        uint256 maxInputAmount
    ) private view returns (V3SwapCallbackData memory) {
        return V3SwapCallbackData({
            payer: address(this),
            inputToken: tokenIn,
            v3Token: stockToken,
            maxInputAmount: maxInputAmount,
            oracleFeeBudget: 0,
            priceUpdateData: new bytes[](0)
        });
    }

    function _sellExactInputOnV3(
        address token,
        uint256 amount
    ) private returns (uint256 stableOut) {
        (, stableOut) = _v3Swap(int256(amount), token, address(this), _routerCtxForV3(token, token, amount));
    }

    function _buyExactInputOnV3(
        address token,
        uint256 stablecoinAmount,
        address recipient
    ) private returns (uint256 stockOut) {
        (, stockOut) = _v3Swap(
            int256(stablecoinAmount),
            address(stablecoin),
            recipient,
            _routerCtxForV3(token, address(stablecoin), stablecoinAmount)
        );
    }

    function _sellExactOutputOnV3(
        address token,
        uint256 stablecoinAmount,
        address recipient,
        uint256 maxInputAmount
    ) private returns (uint256 stockUsed) {
        (stockUsed, ) = _v3Swap(
            -int256(stablecoinAmount),
            token,
            recipient,
            _routerCtxForV3(token, token, maxInputAmount)
        );
    }

    function _buyExactOutputOnV3(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 maxStablecoinAmount
    ) private returns (uint256 stableUsed) {
        (stableUsed, ) = _v3Swap(
            -int256(tokenAmount),
            address(stablecoin),
            recipient,
            _routerCtxForV3(token, address(stablecoin), maxStablecoinAmount)
        );
    }

    // ============ Cross-Pool ExactOutput Helper ============



    // ============ Internal Helpers ============

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
