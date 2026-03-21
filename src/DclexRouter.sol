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
    IWETH9
} from "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

contract DclexRouter is Ownable, IDclexSwapCallback {
    using SafeERC20 for IERC20;

    error DclexRouter__InputTooHigh();
    error DclexRouter__OutputTooLow();
    error DclexRouter__DeadlinePassed();
    error DclexRouter__NativeTransferFailed();
    error DclexRouter__UnknownToken();
    error DclexRouter__NotDclexPool();
    error DclexRouter__InvalidPoolType();

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
    IWETH9 public immutable weth;
    IERC20 public immutable usdc;
    uint24 public constant V3_FEE_TIER = 3000; // 0.3%

    // Pool type registry (embedded in router)
    mapping(address => PoolType) public stockPoolType;
    mapping(address => DclexPool) public stockToCustomPool; // for CUSTOM type
    mapping(address => address) public stockToAMMPool; // for AMM type (V3 pool address)

    // Legacy compatibility - maintains list of custom pool tokens
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
        IWETH9 _weth,
        IERC20 _usdc
    ) Ownable(msg.sender) {
        v3SwapRouter = _v3SwapRouter;
        weth = _weth;
        usdc = _usdc;
    }

    receive() external payable {}

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

    /// @notice Normalize token address: address(0) -> weth for native DEL support
    function _normalizeToken(address token) internal view returns (address) {
        return token == address(0) ? address(weth) : token;
    }

    // ============ Pool Registry Functions ============

    function setCustomPool(address token, DclexPool pool) external onlyOwner {
        if (address(pool) == address(0)) {
            // Remove pool
            DclexPool oldPool = stockToCustomPool[token];
            pools[address(oldPool)] = false;
            stockPoolType[token] = PoolType.NONE;
            delete stockToCustomPool[token];
            _removeFromStockTokens(token);
        } else {
            // Add/update pool
            pools[address(pool)] = true;
            stockPoolType[token] = PoolType.CUSTOM;
            stockToCustomPool[token] = pool;
            _addToStockTokens(token);
        }
        emit CustomPoolSet(token, address(pool));
        emit PoolSetForToken(token, address(pool), PoolType.CUSTOM);
    }

    function setAMMPool(address token, address v3Pool) external onlyOwner {
        if (v3Pool == address(0)) {
            // Remove pool
            stockPoolType[token] = PoolType.NONE;
            delete stockToAMMPool[token];
            _removeFromStockTokens(token);
        } else {
            // Add/update pool
            stockPoolType[token] = PoolType.AMM;
            stockToAMMPool[token] = v3Pool;
            _addToStockTokens(token);
        }
        emit AMMPoolSet(token, v3Pool);
        emit PoolSetForToken(token, v3Pool, PoolType.AMM);
    }

    // Legacy setPool function for backwards compatibility (Custom pools only)
    function setPool(address token, DclexPool dclexPool) external onlyOwner {
        if (address(dclexPool) == address(0)) {
            DclexPool oldPool = stockToCustomPool[token];
            pools[address(oldPool)] = false;
            stockPoolType[token] = PoolType.NONE;
            delete stockToCustomPool[token];
            _removeFromStockTokens(token);
        } else {
            pools[address(dclexPool)] = true;
            stockPoolType[token] = PoolType.CUSTOM;
            stockToCustomPool[token] = dclexPool;
            _addToStockTokens(token);
        }
        emit PoolSetForToken(token, address(dclexPool), PoolType.CUSTOM);
    }

    // Legacy function for backwards compatibility
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
            if (data.inputToken == address(0)) {
                // ETH input: swap via V3 ETH/USDC pool
                inputAmount = _swapEthToUsdcExactOutput(amount, msg.sender);
            } else {
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
        address normalizedToken = _normalizeToken(token);
        PoolType poolType = stockPoolType[normalizedToken];

        if (poolType == PoolType.CUSTOM) {
            inputAmount = _getCustomPool(normalizedToken).swapExactOutput{
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
            // AMM: pull max USDC from user, swap USDC -> token via V3, refund excess
            usdc.safeTransferFrom(msg.sender, address(this), maxInputAmount);

            // For native DEL (address(0)), swap to wDEL then unwrap
            if (token == address(0)) {
                inputAmount = _swapUsdcToAMMExactOutput(
                    address(weth),
                    exactOutputAmount,
                    address(this)
                );
                weth.withdraw(exactOutputAmount);
                _sendEth(msg.sender, exactOutputAmount);
            } else {
                inputAmount = _swapUsdcToAMMExactOutput(
                    normalizedToken,
                    exactOutputAmount,
                    msg.sender
                );
            }
            // Refund unused USDC
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
        address normalizedToken = _normalizeToken(token);
        PoolType poolType = stockPoolType[normalizedToken];

        if (poolType == PoolType.CUSTOM) {
            inputAmount = _getCustomPool(normalizedToken).swapExactOutput{
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
            // For native DEL (address(0)), wrap to wDEL first
            if (token == address(0)) {
                require(
                    msg.value == maxInputAmount,
                    "DclexRouter: msg.value mismatch"
                );
                weth.deposit{value: maxInputAmount}();
            } else {
                // AMM: pull max token from user
                IERC20(normalizedToken).safeTransferFrom(
                    msg.sender,
                    address(this),
                    maxInputAmount
                );
            }
            inputAmount = _swapAMMToUsdcExactOutput(
                normalizedToken,
                exactOutputAmount,
                msg.sender
            );
            // Refund unused tokens
            uint256 refund = maxInputAmount - inputAmount;
            if (refund > 0) {
                if (token == address(0)) {
                    weth.withdraw(refund);
                    _sendEth(msg.sender, refund);
                } else {
                    IERC20(normalizedToken).safeTransfer(msg.sender, refund);
                }
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
        address normalizedToken = _normalizeToken(token);
        PoolType poolType = stockPoolType[normalizedToken];

        if (poolType == PoolType.CUSTOM) {
            outputAmount = _getCustomPool(normalizedToken).swapExactInput{
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
            // AMM: pull USDC from user, then swap USDC -> token via V3
            usdc.safeTransferFrom(msg.sender, address(this), exactInputAmount);

            // For native DEL (address(0)), swap to wDEL then unwrap
            if (token == address(0)) {
                outputAmount = _swapUsdcToAMMExactInput(
                    address(weth),
                    exactInputAmount,
                    address(this)
                );
                weth.withdraw(outputAmount);
                _sendEth(msg.sender, outputAmount);
            } else {
                outputAmount = _swapUsdcToAMMExactInput(
                    normalizedToken,
                    exactInputAmount,
                    msg.sender
                );
            }
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
        address normalizedToken = _normalizeToken(token);
        PoolType poolType = stockPoolType[normalizedToken];

        if (poolType == PoolType.CUSTOM) {
            outputAmount = _getCustomPool(normalizedToken).swapExactInput{
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
            // For native DEL (address(0)), wrap to wDEL first
            if (token == address(0)) {
                require(
                    msg.value == exactInputAmount,
                    "DclexRouter: msg.value mismatch"
                );
                weth.deposit{value: exactInputAmount}();
            } else {
                // AMM: pull token from user
                IERC20(normalizedToken).safeTransferFrom(
                    msg.sender,
                    address(this),
                    exactInputAmount
                );
            }
            outputAmount = _swapAMMToUsdcExactInput(
                normalizedToken,
                exactInputAmount
            );
            // Transfer USDC output to user
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
        if (inputToken == address(0)) {
            // ETH input: update price feeds first, then swap via V3
            _updatePriceFeeds(outputToken, pythUpdateData);
            usdcAmount = _swapEthToUsdcExactInput(exactInputAmount);
        } else {
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
                // For AMM input, transfer tokens and swap via V3
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
        }

        // Step 2: USDC -> Output
        if (outputToken == address(0)) {
            // ETH output: swap via V3
            outputAmount = _swapUsdcToEthExactInput(usdcAmount);
            _sendEth(msg.sender, outputAmount);
        } else {
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
        }

        if (outputAmount < minOutputAmount) {
            revert DclexRouter__OutputTooLow();
        }
        _refundEth();
    }

    function swapExactOutput(
        address inputToken,
        address outputToken,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        uint256 deadline,
        bytes[] calldata pythUpdateData
    ) external payable checkDeadline(deadline) {
        _executeSwapExactOutput(
            inputToken,
            outputToken,
            exactOutputAmount,
            maxInputAmount,
            pythUpdateData
        );
        _refundEth();
    }

    function _executeSwapExactOutput(
        address inputToken,
        address outputToken,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        bytes[] calldata pythUpdateData
    ) private {
        if (outputToken != address(0)) {
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
                // 1. Acquire USDC from input first (sell input tokens)
                uint256 usdcAcquired = _acquireUsdcFromInput(
                    inputToken,
                    maxInputAmount,
                    msg.sender,
                    pythUpdateData
                );

                // 2. Now swap USDC → output token (exact output)
                uint256 usdcUsed = _swapUsdcToAMMExactOutput(
                    outputToken,
                    exactOutputAmount,
                    msg.sender
                );

                // 3. Check we had enough
                if (usdcUsed > usdcAcquired) {
                    revert DclexRouter__InputTooHigh();
                }
            } else {
                revert DclexRouter__UnknownToken();
            }
        } else {
            // ETH output via V3
            _updatePriceFeeds(inputToken, pythUpdateData);
            uint256 inputAmount = _swapInputToEthExactOutput(
                inputToken,
                exactOutputAmount,
                msg.sender
            );
            if (inputAmount > maxInputAmount) {
                revert DclexRouter__InputTooHigh();
            }
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

    // ============ V3 Swap Helpers (ETH/USDC) ============

    function _swapEthToUsdcExactInput(
        uint256 ethAmount
    ) private returns (uint256) {
        weth.deposit{value: ethAmount}();
        IERC20(address(weth)).safeIncreaseAllowance(
            address(v3SwapRouter),
            ethAmount
        );

        return
            v3SwapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(weth),
                    tokenOut: address(usdc),
                    fee: V3_FEE_TIER,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: ethAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _swapUsdcToEthExactInput(
        uint256 usdcAmount
    ) private returns (uint256) {
        usdc.safeIncreaseAllowance(address(v3SwapRouter), usdcAmount);

        uint256 wethAmount = v3SwapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                fee: V3_FEE_TIER,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdcAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        weth.withdraw(wethAmount);
        return wethAmount;
    }

    function _swapEthToUsdcExactOutput(
        uint256 usdcAmount,
        address recipient
    ) private returns (uint256) {
        // Wrap all available ETH
        uint256 ethBalance = address(this).balance;
        weth.deposit{value: ethBalance}();
        IERC20(address(weth)).safeIncreaseAllowance(
            address(v3SwapRouter),
            ethBalance
        );

        uint256 ethUsed = v3SwapRouter.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(usdc),
                fee: V3_FEE_TIER,
                recipient: recipient,
                deadline: block.timestamp,
                amountOut: usdcAmount,
                amountInMaximum: ethBalance,
                sqrtPriceLimitX96: 0
            })
        );

        // Unwrap excess WETH back to ETH for refund
        uint256 excessWeth = IERC20(address(weth)).balanceOf(address(this));
        if (excessWeth > 0) {
            weth.withdraw(excessWeth);
        }

        return ethUsed;
    }

    function _swapInputToEthExactOutput(
        address inputToken,
        uint256 ethOutputAmount,
        address recipient
    ) private returns (uint256) {
        // First get USDC amount needed for this ETH output
        // Use V3 to swap USDC -> ETH exact output
        uint256 usdcNeeded = _getUsdcForEthOutput(ethOutputAmount);

        // Get USDC from input token
        uint256 inputAmount;
        PoolType inputType = stockPoolType[inputToken];
        if (inputType == PoolType.CUSTOM) {
            inputAmount = stockToCustomPool[inputToken].swapExactOutput(
                false,
                usdcNeeded,
                address(this),
                abi.encode(
                    DclexSwapCallbackData(recipient, false, address(0), 0)
                ),
                new bytes[](0)
            );
        } else if (inputType == PoolType.AMM) {
            inputAmount = _swapAMMToUsdcExactOutput(
                inputToken,
                usdcNeeded,
                address(this)
            );
        } else {
            revert DclexRouter__UnknownToken();
        }

        // Now swap USDC -> ETH exact input (we have exact USDC amount)
        uint256 ethReceived = _swapUsdcToEthExactInput(usdcNeeded);
        _sendEth(recipient, ethReceived);

        return inputAmount;
    }

    function _getUsdcForEthOutput(uint256 ethAmount) private returns (uint256) {
        // Estimate by doing a small calculation based on pool
        // For simplicity, we do an exact output swap to get exact USDC needed
        usdc.safeIncreaseAllowance(address(v3SwapRouter), type(uint256).max);

        uint256 usdcBalance = usdc.balanceOf(address(this));
        uint256 usdcUsed = v3SwapRouter.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                fee: V3_FEE_TIER,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: ethAmount,
                amountInMaximum: usdcBalance > 0
                    ? usdcBalance
                    : type(uint256).max,
                sqrtPriceLimitX96: 0
            })
        );

        // Unwrap WETH to ETH
        weth.withdraw(ethAmount);

        return usdcUsed;
    }

    // ============ V3 Swap Helpers (AMM Token/USDC) ============

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
                    fee: V3_FEE_TIER,
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
                    fee: V3_FEE_TIER,
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
                    fee: V3_FEE_TIER,
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
        address recipient
    ) private returns (uint256) {
        uint256 usdcBalance = usdc.balanceOf(address(this));
        usdc.safeIncreaseAllowance(address(v3SwapRouter), usdcBalance);

        return
            v3SwapRouter.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: token,
                    fee: V3_FEE_TIER,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: tokenAmount,
                    amountInMaximum: usdcBalance,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    // ============ Helper Functions ============

    function _acquireUsdcFromInput(
        address inputToken,
        uint256 usdcAmount,
        address payer,
        bytes[] calldata pythUpdateData
    ) private returns (uint256) {
        if (inputToken == address(0)) {
            // ETH input
            return _swapEthToUsdcExactOutput(usdcAmount, address(this));
        }

        PoolType inputType = stockPoolType[inputToken];
        if (inputType == PoolType.CUSTOM) {
            return
                stockToCustomPool[inputToken].swapExactOutput{value: msg.value}(
                    false,
                    usdcAmount,
                    address(this),
                    abi.encode(
                        DclexSwapCallbackData(payer, false, address(0), 0)
                    ),
                    pythUpdateData
                );
        } else if (inputType == PoolType.AMM) {
            // Transfer tokens from payer, then swap
            uint256 inputAmount = _swapAMMToUsdcExactOutput(
                inputToken,
                usdcAmount,
                address(this)
            );
            return inputAmount;
        } else {
            revert DclexRouter__UnknownToken();
        }
    }

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

    function _refundEth() private {
        if (address(this).balance > 0) {
            (bool success, ) = msg.sender.call{value: address(this).balance}(
                new bytes(0)
            );
            if (!success) revert DclexRouter__NativeTransferFailed();
        }
    }

    function _sendEth(address recipient, uint256 amount) private {
        (bool success, ) = recipient.call{value: amount}(new bytes(0));
        if (!success) revert DclexRouter__NativeTransferFailed();
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
        // Check if already exists
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
