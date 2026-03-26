// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IDclexSwapCallback} from "dclex-protocol/src/IDclexSwapCallback.sol";
import {
    ISwapRouter
} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {
    IQuoter
} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

/// @title DclexRouter
/// @notice Unified router for dual-DEX: DCLEX oracle pools (CUSTOM) + Uniswap V3 AMM pools
/// @dev wDEL (wrapped DEL) is treated as a normal AMM token — wrapping/unwrapping is frontend responsibility
contract DclexRouter is Ownable, IDclexSwapCallback {
    using SafeERC20 for IERC20;

    error DclexRouter__InputTooHigh();
    error DclexRouter__OutputTooLow();
    error DclexRouter__DeadlinePassed();
    error DclexRouter__UnknownToken();
    error DclexRouter__NotDclexPool();

    enum PoolType {
        NONE,
        CUSTOM,
        AMM
    }

    struct DclexSwapCallbackData {
        address payer;
        bool payWithSwapExactOutput;
        address inputToken;
        uint256 maxInputAmount;
    }

    // V3 infrastructure
    ISwapRouter public immutable v3SwapRouter;
    IQuoter public immutable v3Quoter;
    IERC20 public immutable usdc;
    uint24 public constant DEFAULT_FEE_TIER = 3000; // 0.3%

    // Pool type registry
    mapping(address => PoolType) public stockPoolType;
    mapping(address => DclexPool) public stockToCustomPool;
    mapping(address => address) public stockToAMMPool;
    mapping(address => uint24) public stockToFeeTier;

    // Legacy compatibility
    address[] private stockTokens;
    mapping(address => bool) private pools;

    event PoolSetForToken(
        address indexed token,
        address pool,
        PoolType poolType
    );
    event CustomPoolSet(address indexed token, address pool);
    event AMMPoolSet(address indexed token, address v3Pool);

    constructor(
        ISwapRouter _v3SwapRouter,
        IQuoter _v3Quoter,
        IERC20 _usdc
    ) Ownable(msg.sender) {
        v3SwapRouter = _v3SwapRouter;
        v3Quoter = _v3Quoter;
        usdc = _usdc;
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

    function _getFeeTier(address token) internal view returns (uint24) {
        uint24 feeTier = stockToFeeTier[token];
        return feeTier > 0 ? feeTier : DEFAULT_FEE_TIER;
    }

    // ============ Pool Registry Functions ============

    function setCustomPool(address token, DclexPool pool) external onlyOwner {
        if (address(pool) == address(0)) {
            DclexPool oldPool = stockToCustomPool[token];
            pools[address(oldPool)] = false;
            stockPoolType[token] = PoolType.NONE;
            delete stockToCustomPool[token];
            _removeFromStockTokens(token);
            emit CustomPoolSet(token, address(0));
            emit PoolSetForToken(token, address(0), PoolType.NONE);
        } else {
            pools[address(pool)] = true;
            stockPoolType[token] = PoolType.CUSTOM;
            stockToCustomPool[token] = pool;
            _addToStockTokens(token);
            emit CustomPoolSet(token, address(pool));
            emit PoolSetForToken(token, address(pool), PoolType.CUSTOM);
        }
    }

    function setAMMPool(
        address token,
        address v3Pool,
        uint24 feeTier
    ) external onlyOwner {
        if (v3Pool == address(0)) {
            stockPoolType[token] = PoolType.NONE;
            delete stockToAMMPool[token];
            delete stockToFeeTier[token];
            _removeFromStockTokens(token);
            emit AMMPoolSet(token, address(0));
            emit PoolSetForToken(token, address(0), PoolType.NONE);
        } else {
            stockPoolType[token] = PoolType.AMM;
            stockToAMMPool[token] = v3Pool;
            stockToFeeTier[token] = feeTier;
            _addToStockTokens(token);
            emit AMMPoolSet(token, v3Pool);
            emit PoolSetForToken(token, v3Pool, PoolType.AMM);
        }
    }

    // Legacy setPool function (Custom pools only)
    function setPool(address token, DclexPool dclexPool) external onlyOwner {
        if (address(dclexPool) == address(0)) {
            DclexPool oldPool = stockToCustomPool[token];
            pools[address(oldPool)] = false;
            stockPoolType[token] = PoolType.NONE;
            delete stockToCustomPool[token];
            _removeFromStockTokens(token);
            emit PoolSetForToken(token, address(0), PoolType.NONE);
        } else {
            pools[address(dclexPool)] = true;
            stockPoolType[token] = PoolType.CUSTOM;
            stockToCustomPool[token] = dclexPool;
            _addToStockTokens(token);
            emit PoolSetForToken(token, address(dclexPool), PoolType.CUSTOM);
        }
    }

    function stockTokenToPool(address token) external view returns (DclexPool) {
        return stockToCustomPool[token];
    }

    function getPoolType(address token) public view returns (PoolType) {
        return stockPoolType[token];
    }

    function allStockTokens() external view returns (address[] memory) {
        return stockTokens;
    }

    // ============ Callback ============

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
            uint256 inputAmount;
            PoolType inputType = stockPoolType[data.inputToken];
            if (inputType == PoolType.CUSTOM) {
                inputAmount = stockToCustomPool[data.inputToken]
                    .swapExactOutput(
                        false,
                        amount,
                        msg.sender,
                        abi.encode(
                            DclexSwapCallbackData(
                                data.payer,
                                false,
                                address(0),
                                0
                            )
                        ),
                        new bytes[](0)
                    );
            } else if (inputType == PoolType.AMM) {
                inputAmount = _swapAMMToUsdcExactOutput(
                    data.inputToken,
                    amount,
                    msg.sender
                );
            } else {
                revert DclexRouter__UnknownToken();
            }
            if (inputAmount > data.maxInputAmount) {
                revert DclexRouter__InputTooHigh();
            }
        } else {
            if (data.payer == address(this)) {
                IERC20(token).safeTransfer(msg.sender, amount);
            } else {
                IERC20(token).safeTransferFrom(data.payer, msg.sender, amount);
            }
        }
    }

    // ============ Single-Token Swap Functions (Buy/Sell) ============

    function buyExactOutput(
        address token,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        uint256 deadline,
        bytes[] calldata pythUpdateData
    ) external payable checkDeadline(deadline) {
        uint256 inputAmount;
        PoolType poolType = stockPoolType[token];

        if (poolType == PoolType.CUSTOM) {
            inputAmount = _getCustomPool(token).swapExactOutput{
                value: msg.value
            }(
                true,
                exactOutputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData(msg.sender, false, address(0), 0)
                ),
                pythUpdateData
            );
        } else if (poolType == PoolType.AMM) {
            usdc.safeTransferFrom(msg.sender, address(this), maxInputAmount);
            inputAmount = _swapUsdcToAMMExactOutput(
                token,
                exactOutputAmount,
                msg.sender,
                maxInputAmount
            );
            uint256 refund = maxInputAmount - inputAmount;
            if (refund > 0) {
                usdc.safeTransfer(msg.sender, refund);
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
        bytes[] calldata pythUpdateData
    ) external payable checkDeadline(deadline) {
        uint256 inputAmount;
        PoolType poolType = stockPoolType[token];

        if (poolType == PoolType.CUSTOM) {
            inputAmount = _getCustomPool(token).swapExactOutput{
                value: msg.value
            }(
                false,
                exactOutputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData(msg.sender, false, address(0), 0)
                ),
                pythUpdateData
            );
        } else if (poolType == PoolType.AMM) {
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                maxInputAmount
            );
            inputAmount = _swapAMMToUsdcExactOutput(
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
        bytes[] calldata pythUpdateData
    ) external payable checkDeadline(deadline) {
        uint256 outputAmount;
        PoolType poolType = stockPoolType[token];

        if (poolType == PoolType.CUSTOM) {
            outputAmount = _getCustomPool(token).swapExactInput{
                value: msg.value
            }(
                true,
                exactInputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData(msg.sender, false, address(0), 0)
                ),
                pythUpdateData
            );
        } else if (poolType == PoolType.AMM) {
            usdc.safeTransferFrom(msg.sender, address(this), exactInputAmount);
            outputAmount = _swapUsdcToAMMExactInput(
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
        bytes[] calldata pythUpdateData
    ) external payable checkDeadline(deadline) {
        uint256 outputAmount;
        PoolType poolType = stockPoolType[token];

        if (poolType == PoolType.CUSTOM) {
            outputAmount = _getCustomPool(token).swapExactInput{
                value: msg.value
            }(
                false,
                exactInputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData(msg.sender, false, address(0), 0)
                ),
                pythUpdateData
            );
        } else if (poolType == PoolType.AMM) {
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                exactInputAmount
            );
            outputAmount = _swapAMMToUsdcExactInput(token, exactInputAmount);
            usdc.safeTransfer(msg.sender, outputAmount);
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
        bytes[] calldata pythUpdateData
    ) external payable checkDeadline(deadline) {
        uint256 usdcAmount;
        uint256 outputAmount;

        // Step 1: Input -> USDC
        PoolType inputType = stockPoolType[inputToken];
        if (inputType == PoolType.CUSTOM) {
            bytes memory callbackData = _encodeSwapCallback(
                msg.sender,
                false,
                address(0),
                0
            );
            usdcAmount = stockToCustomPool[inputToken].swapExactInput{
                value: msg.value
            }(
                false,
                exactInputAmount,
                address(this),
                callbackData,
                pythUpdateData
            );
        } else if (inputType == PoolType.AMM) {
            IERC20(inputToken).safeTransferFrom(
                msg.sender,
                address(this),
                exactInputAmount
            );
            usdcAmount = _swapAMMToUsdcExactInput(
                inputToken,
                exactInputAmount
            );
        } else {
            revert DclexRouter__UnknownToken();
        }

        // Step 2: USDC -> Output
        PoolType outputType = stockPoolType[outputToken];
        if (outputType == PoolType.CUSTOM) {
            bytes memory callbackData = _encodeSwapCallback(
                address(this),
                false,
                address(0),
                0
            );
            outputAmount = stockToCustomPool[outputToken].swapExactInput(
                true,
                usdcAmount,
                msg.sender,
                callbackData,
                new bytes[](0)
            );
        } else if (outputType == PoolType.AMM) {
            outputAmount = _swapUsdcToAMMExactInput(
                outputToken,
                usdcAmount,
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
        bytes[] calldata pythUpdateData
    ) external payable checkDeadline(deadline) {
        PoolType outputType = stockPoolType[outputToken];
        if (outputType == PoolType.CUSTOM) {
            bytes memory callbackData = _encodeSwapCallback(
                msg.sender,
                true,
                inputToken,
                maxInputAmount
            );
            stockToCustomPool[outputToken].swapExactOutput{
                value: msg.value
            }(
                true,
                exactOutputAmount,
                msg.sender,
                callbackData,
                pythUpdateData
            );
        } else if (outputType == PoolType.AMM) {
            _executeAMMOutputSwap(
                inputToken,
                outputToken,
                exactOutputAmount,
                maxInputAmount,
                msg.sender,
                pythUpdateData
            );
        } else {
            revert DclexRouter__UnknownToken();
        }
    }

    // ============ Callback Data Helper ============

    function _encodeSwapCallback(
        address payer,
        bool payWithSwapExactOutput,
        address inputToken,
        uint256 maxInputAmount
    ) private pure returns (bytes memory) {
        return
            abi.encode(
                DclexSwapCallbackData(
                    payer,
                    payWithSwapExactOutput,
                    inputToken,
                    maxInputAmount
                )
            );
    }

    // ============ V3 Swap Helpers ============

    function _swapAMMToUsdcExactInput(
        address token,
        uint256 amount
    ) private returns (uint256) {
        IERC20(token).safeIncreaseAllowance(address(v3SwapRouter), amount);
        return
            v3SwapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: address(usdc),
                    fee: _getFeeTier(token),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _swapUsdcToAMMExactInput(
        address token,
        uint256 usdcAmount,
        address recipient
    ) private returns (uint256) {
        usdc.safeIncreaseAllowance(address(v3SwapRouter), usdcAmount);
        return
            v3SwapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: token,
                    fee: _getFeeTier(token),
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: usdcAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _swapAMMToUsdcExactOutput(
        address token,
        uint256 usdcAmount,
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
                    tokenOut: address(usdc),
                    fee: _getFeeTier(token),
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: usdcAmount,
                    amountInMaximum: tokenBalance,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _swapUsdcToAMMExactOutput(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 maxUsdcAmount
    ) private returns (uint256) {
        usdc.safeIncreaseAllowance(address(v3SwapRouter), maxUsdcAmount);
        return
            v3SwapRouter.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: token,
                    fee: _getFeeTier(token),
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: tokenAmount,
                    amountInMaximum: maxUsdcAmount,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    // ============ Cross-Pool ExactOutput Helper ============

    /// @notice Execute a swap where output is an AMM token
    /// @dev Uses Quoter to determine exact USDC needed, then exact-output on both legs
    function _executeAMMOutputSwap(
        address inputToken,
        address outputToken,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        address payer,
        bytes[] calldata pythUpdateData
    ) private {
        // Step 1: Quote how much USDC is needed for the V3 exact output
        uint256 usdcNeeded = v3Quoter.quoteExactOutputSingle(
            address(usdc),
            outputToken,
            _getFeeTier(outputToken),
            exactOutputAmount,
            0
        );

        // Step 2: Acquire exactly that much USDC from the input
        uint256 inputUsed;
        PoolType inputType = stockPoolType[inputToken];

        if (inputType == PoolType.CUSTOM) {
            inputUsed = stockToCustomPool[inputToken].swapExactOutput{
                value: msg.value
            }(
                false,
                usdcNeeded,
                address(this),
                abi.encode(
                    DclexSwapCallbackData(payer, false, address(0), 0)
                ),
                pythUpdateData
            );
        } else if (inputType == PoolType.AMM) {
            IERC20(inputToken).safeTransferFrom(
                payer,
                address(this),
                maxInputAmount
            );
            inputUsed = _swapAMMToUsdcExactOutput(
                inputToken,
                usdcNeeded,
                address(this)
            );
            uint256 remainingInput = IERC20(inputToken).balanceOf(address(this));
            if (remainingInput > 0) {
                IERC20(inputToken).safeTransfer(payer, remainingInput);
            }
        } else {
            revert DclexRouter__UnknownToken();
        }

        if (inputUsed > maxInputAmount) {
            revert DclexRouter__InputTooHigh();
        }

        // Step 3: Swap USDC -> output token (exact output)
        _swapUsdcToAMMExactOutput(
            outputToken,
            exactOutputAmount,
            payer,
            usdcNeeded
        );
    }

    // ============ Internal Helpers ============

    function _updatePriceFeeds(
        address token,
        bytes[] calldata pythUpdateData
    ) private {
        PoolType poolType = stockPoolType[token];
        if (poolType == PoolType.CUSTOM && pythUpdateData.length > 0) {
            stockToCustomPool[token].updatePriceFeeds{value: msg.value}(
                pythUpdateData
            );
        }
    }

    function _getCustomPool(address token) private view returns (DclexPool) {
        if (stockPoolType[token] != PoolType.CUSTOM) {
            revert DclexRouter__UnknownToken();
        }
        DclexPool pool = stockToCustomPool[token];
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
