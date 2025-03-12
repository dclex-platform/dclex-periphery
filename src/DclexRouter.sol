// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IDclexSwapCallback} from "dclex-protocol/src/IDclexSwapCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DclexRouter is SafeCallback, Ownable, IDclexSwapCallback {
    error DclexRouter__InputTooHigh();
    error DclexRouter__OutputTooLow();
    error DclexRouter__DeadlinePassed();
    error DclexRouter__NativeTransferFailed();
    error DclexRouter__UnknownToken();
    error DclexRouter__NotDclexPool();

    enum UniswapOperation {
        EthToUsdcExactInput,
        UsdcToEthExactInput,
        EthToUsdcExactOutput,
        StockToEthExactOutput
    }

    struct UniswapCallbackData {
        UniswapOperation operation;
        uint256 amount;
        address swapper;
        address stockToken;
    }

    struct DclexSwapCallbackData {
        address payer;
        bool payWithSwapExactOutput;
        address inputToken;
        uint256 maxInputAmount;
    }

    mapping(address => DclexPool) public stockTokenToPool;
    mapping(address => bool) private pools;
    PoolKey private ethUsdcPoolKey;

    event PoolSetForToken(address token, address pool);

    constructor(
        IPoolManager _uniswapV4PoolManager,
        PoolKey memory _ethUsdcPoolKey
    ) SafeCallback(_uniswapV4PoolManager) Ownable(msg.sender) {
        ethUsdcPoolKey = _ethUsdcPoolKey;
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

    function setPool(address token, DclexPool dclexPool) external onlyOwner {
        if (address(dclexPool) == address(0)) {
            DclexPool oldPool = stockTokenToPool[token];
            pools[address(oldPool)] = false;
        } else {
            pools[address(dclexPool)] = true;
        }
        stockTokenToPool[token] = dclexPool;
        emit PoolSetForToken(token, address(dclexPool));
    }

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
                inputAmount = _executeUniswapOperation(
                    UniswapOperation.EthToUsdcExactOutput,
                    amount,
                    msg.sender,
                    data.inputToken
                );
            } else {
                inputAmount = _getPool(data.inputToken).swapExactOutput(
                    false,
                    amount,
                    msg.sender,
                    abi.encode(
                        DclexSwapCallbackData(data.payer, false, address(0), 0)
                    ),
                    new bytes[](0)
                );
            }
            if (inputAmount > data.maxInputAmount) {
                revert DclexRouter__InputTooHigh();
            }
        } else {
            IERC20(token).transferFrom(data.payer, msg.sender, amount);
        }
    }

    function buyExactOutput(
        address token,
        uint256 exactOutputAmount,
        uint256 maxInputAmount,
        uint256 deadline,
        bytes[] calldata pythUpdateData
    ) external payable checkDeadline(deadline) {
        uint256 inputAmount = _getPool(token).swapExactOutput{value: msg.value}(
            true,
            exactOutputAmount,
            msg.sender,
            abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
            pythUpdateData
        );
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
        uint256 inputAmount = _getPool(token).swapExactOutput{value: msg.value}(
            false,
            exactOutputAmount,
            msg.sender,
            abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
            pythUpdateData
        );
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
        uint256 outputAmount = _getPool(token).swapExactInput{value: msg.value}(
            true,
            exactInputAmount,
            msg.sender,
            abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
            pythUpdateData
        );
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
        uint256 outputAmount = _getPool(token).swapExactInput{value: msg.value}(
            false,
            exactInputAmount,
            msg.sender,
            abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
            pythUpdateData
        );
        if (outputAmount < minOutputAmount) {
            revert DclexRouter__OutputTooLow();
        }
    }

    function _executeUniswapOperation(
        UniswapOperation operation,
        uint256 amount,
        address swapper,
        address stockToken
    ) private returns (uint128) {
        UniswapCallbackData memory callbackData = UniswapCallbackData(
            operation,
            amount,
            swapper,
            stockToken
        );
        bytes memory result = poolManager.unlock(abi.encode(callbackData));
        return abi.decode(result, (uint128));
    }

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

        if (inputToken != address(0)) {
            usdcAmount = _getPool(inputToken).swapExactInput{value: msg.value}(
                false,
                exactInputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData(msg.sender, false, address(0), 0)
                ),
                pythUpdateData
            );
        } else {
            _getPool(outputToken).updatePythPriceFeeds{value: msg.value}(
                pythUpdateData
            );
            usdcAmount = _executeUniswapOperation(
                UniswapOperation.EthToUsdcExactInput,
                exactInputAmount,
                msg.sender,
                address(0)
            );
        }
        if (outputToken != address(0)) {
            outputAmount = _getPool(outputToken).swapExactInput(
                true,
                usdcAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData(msg.sender, false, address(0), 0)
                ),
                new bytes[](0)
            );
        } else {
            outputAmount = _executeUniswapOperation(
                UniswapOperation.UsdcToEthExactInput,
                usdcAmount,
                msg.sender,
                address(0)
            );
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
        if (outputToken != address(0)) {
            _getPool(outputToken).swapExactOutput{value: msg.value}(
                true,
                exactOutputAmount,
                msg.sender,
                abi.encode(
                    DclexSwapCallbackData(
                        msg.sender,
                        true,
                        inputToken,
                        maxInputAmount
                    )
                ),
                pythUpdateData
            );
        } else {
            _getPool(inputToken).updatePythPriceFeeds{value: msg.value}(
                pythUpdateData
            );
            uint256 inputAmount = _executeUniswapOperation(
                UniswapOperation.StockToEthExactOutput,
                exactOutputAmount,
                msg.sender,
                inputToken
            );
            if (inputAmount > maxInputAmount) {
                revert DclexRouter__InputTooHigh();
            }
        }
        _refundEth();
    }

    function _unlockCallback(
        bytes calldata callbackData
    ) internal override returns (bytes memory) {
        UniswapCallbackData memory data = abi.decode(
            callbackData,
            (UniswapCallbackData)
        );
        if (data.operation == UniswapOperation.EthToUsdcExactInput) {
            return _uniswapEthToUsdcExactInput(data.amount, data.swapper);
        } else if (data.operation == UniswapOperation.UsdcToEthExactInput) {
            return _uniswapUsdcToEthExactInput(data.amount, data.swapper);
        } else if (data.operation == UniswapOperation.EthToUsdcExactOutput) {
            return _uniswapEthToUsdcExactOutput(data.amount, data.swapper);
        } else if (data.operation == UniswapOperation.StockToEthExactOutput) {
            return
                _uniswapStockToEthExactOutput(
                    data.stockToken,
                    data.amount,
                    data.swapper
                );
        }
    }

    function _uniswapUsdcToEthExactInput(
        uint256 inputAmount,
        address recipient
    ) private returns (bytes memory) {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            false,
            -int256(inputAmount),
            TickMath.MAX_SQRT_PRICE - 1
        );
        BalanceDelta delta = poolManager.swap(ethUsdcPoolKey, params, "");
        uint128 amount0 = uint128(delta.amount0());
        uint128 amount1 = uint128(-delta.amount1());
        poolManager.sync(ethUsdcPoolKey.currency1);
        IERC20(Currency.unwrap(ethUsdcPoolKey.currency1)).transferFrom(
            recipient,
            address(poolManager),
            amount1
        );
        poolManager.settle();
        poolManager.take(ethUsdcPoolKey.currency0, recipient, amount0);
        return abi.encode(amount0);
    }

    function _uniswapEthToUsdcExactInput(
        uint256 inputAmount,
        address recipient
    ) private returns (bytes memory) {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            true,
            -int256(inputAmount),
            TickMath.MIN_SQRT_PRICE + 1
        );
        BalanceDelta delta = poolManager.swap(ethUsdcPoolKey, params, "");
        uint128 amount0 = uint128(-delta.amount0());
        uint128 amount1 = uint128(delta.amount1());
        poolManager.settle{value: amount0}();
        poolManager.take(ethUsdcPoolKey.currency1, recipient, amount1);
        return abi.encode(amount1);
    }

    function _uniswapStockToEthExactOutput(
        address inputToken,
        uint256 outputAmount,
        address swapper
    ) private returns (bytes memory) {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            false,
            int256(outputAmount),
            TickMath.MAX_SQRT_PRICE - 1
        );
        BalanceDelta delta = poolManager.swap(ethUsdcPoolKey, params, "");
        uint128 amount0 = uint128(delta.amount0());
        poolManager.take(ethUsdcPoolKey.currency0, swapper, amount0);
        uint256 usdcAmount = uint128(-delta.amount1());
        poolManager.sync(ethUsdcPoolKey.currency1);
        uint256 inputAmount = _getPool(inputToken).swapExactOutput(
            false,
            usdcAmount,
            address(poolManager),
            abi.encode(DclexSwapCallbackData(swapper, false, address(0), 0)),
            new bytes[](0)
        );
        poolManager.settle();
        return abi.encode(inputAmount);
    }

    function _uniswapEthToUsdcExactOutput(
        uint256 outputAmount,
        address dclexPool
    ) private returns (bytes memory) {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            true,
            int256(outputAmount),
            TickMath.MIN_SQRT_PRICE + 1
        );
        BalanceDelta delta = poolManager.swap(ethUsdcPoolKey, params, "");
        uint128 amount0 = uint128(-delta.amount0());
        uint128 amount1 = uint128(delta.amount1());
        poolManager.settle{value: amount0}();
        poolManager.take(ethUsdcPoolKey.currency1, dclexPool, amount1);
        return abi.encode(amount0);
    }

    function _refundEth() private {
        if (address(this).balance > 0) {
            (bool success, ) = msg.sender.call{value: address(this).balance}(
                new bytes(0)
            );
            if (!success) revert DclexRouter__NativeTransferFailed();
        }
    }

    function _getPool(address token) private view returns (DclexPool) {
        DclexPool pool = stockTokenToPool[token];
        if (address(pool) == address(0)) {
            revert DclexRouter__UnknownToken();
        }
        return pool;
    }
}
