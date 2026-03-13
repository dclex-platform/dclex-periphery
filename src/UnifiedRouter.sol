// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IDclexSwapCallback} from "dclex-protocol/src/IDclexSwapCallback.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @title UnifiedRouter
/// @notice Routes swaps through DclexPool (signature-based pricing) or V3Pool (AMM-driven)
/// @dev All swaps use dUSD as the hub token
contract UnifiedRouter is Ownable, ReentrancyGuard, IDclexSwapCallback, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    error UnifiedRouter__InputTooHigh();
    error UnifiedRouter__OutputTooLow();
    error UnifiedRouter__DeadlinePassed();
    error UnifiedRouter__NativeTransferFailed();
    error UnifiedRouter__UnknownToken();
    error UnifiedRouter__NotDclexPool();
    error UnifiedRouter__NotV3Pool();
    error UnifiedRouter__InvalidCallback();

    /// @notice Pool type enum
    enum PoolType {
        None,
        Dclex,
        V3
    }

    /// @notice Callback data for DclexPool swaps
    struct DclexSwapCallbackData {
        address payer;
        bool payWithCrossPoolSwap;
        address inputToken;
        uint256 maxInputAmount;
    }

    /// @notice Callback data for V3 swaps
    struct V3CallbackData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address payer;
    }

    /// @notice dUSD token (hub for all swaps)
    IERC20 public immutable dUSD;

    /// @notice Wrapped native token
    address public immutable wdel;

    /// @notice V3 factory for pool lookups
    IUniswapV3Factory public immutable v3Factory;

    /// @notice Default fee tier for V3 pools
    uint24 public constant DEFAULT_FEE = 3000;

    /// @notice Stock tokens to DclexPool mapping
    mapping(address => DclexPool) public dclexPools;

    /// @notice Token to V3Pool mapping (stores pool address directly)
    mapping(address => address) public v3Pools;

    /// @notice Track valid DclexPools for callback validation
    mapping(address => bool) private _validDclexPools;

    /// @notice Track valid V3Pools for callback validation
    mapping(address => bool) private _validV3Pools;

    /// @notice All registered stock tokens
    address[] private stockTokens;

    event DclexPoolSet(address indexed token, address indexed pool);
    event V3PoolSet(address indexed token, address indexed pool);

    constructor(
        address _dUSD,
        address _wdel,
        address _v3Factory
    ) Ownable(msg.sender) {
        dUSD = IERC20(_dUSD);
        wdel = _wdel;
        v3Factory = IUniswapV3Factory(_v3Factory);
    }

    receive() external payable {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert UnifiedRouter__DeadlinePassed();
        }
        _;
    }

    // ============ Admin Functions ============

    /// @notice Set DclexPool for a token
    function setDclexPool(address token, DclexPool pool) external onlyOwner {
        if (address(pool) == address(0)) {
            // Remove pool
            DclexPool oldPool = dclexPools[token];
            _validDclexPools[address(oldPool)] = false;
            _removeStockToken(token);
        } else {
            // Add pool
            _validDclexPools[address(pool)] = true;
            if (address(dclexPools[token]) == address(0)) {
                stockTokens.push(token);
            }
        }
        dclexPools[token] = pool;
        emit DclexPoolSet(token, address(pool));
    }

    /// @notice Set V3Pool for a token
    function setV3Pool(address token, address pool) external onlyOwner {
        if (pool == address(0)) {
            // Remove pool
            address oldPool = v3Pools[token];
            _validV3Pools[oldPool] = false;
            _removeStockToken(token);
        } else {
            // Add pool
            _validV3Pools[pool] = true;
            if (v3Pools[token] == address(0) && address(dclexPools[token]) == address(0)) {
                stockTokens.push(token);
            }
        }
        v3Pools[token] = pool;
        emit V3PoolSet(token, pool);
    }

    // ============ View Functions ============

    /// @notice Get all registered stock tokens
    function allStockTokens() external view returns (address[] memory) {
        return stockTokens;
    }

    /// @notice Get pool type for a token
    function getPoolType(address token) external view returns (PoolType) {
        if (address(dclexPools[token]) != address(0)) return PoolType.Dclex;
        if (v3Pools[token] != address(0)) return PoolType.V3;
        return PoolType.None;
    }

    // ============ DclexPool Swap Functions (Backward Compatible) ============

    /// @notice Buy stock with dUSD (exact input)
    function buyExactInput(
        address token,
        uint256 exactInput,
        uint256 minOutput,
        uint256 deadline,
        bytes[] calldata pythData
    ) external payable checkDeadline(deadline) nonReentrant {
        DclexPool pool = _getDclexPool(token);
        uint256 output = pool.swapExactInput{value: msg.value}(
            true,
            exactInput,
            msg.sender,
            abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
            pythData
        );
        if (output < minOutput) revert UnifiedRouter__OutputTooLow();
    }

    /// @notice Buy stock with dUSD (exact output)
    function buyExactOutput(
        address token,
        uint256 exactOutput,
        uint256 maxInput,
        uint256 deadline,
        bytes[] calldata pythData
    ) external payable checkDeadline(deadline) nonReentrant {
        DclexPool pool = _getDclexPool(token);
        uint256 input = pool.swapExactOutput{value: msg.value}(
            true,
            exactOutput,
            msg.sender,
            abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
            pythData
        );
        if (input > maxInput) revert UnifiedRouter__InputTooHigh();
    }

    /// @notice Sell stock for dUSD (exact input)
    function sellExactInput(
        address token,
        uint256 exactInput,
        uint256 minOutput,
        uint256 deadline,
        bytes[] calldata pythData
    ) external payable checkDeadline(deadline) nonReentrant {
        DclexPool pool = _getDclexPool(token);
        uint256 output = pool.swapExactInput{value: msg.value}(
            false,
            exactInput,
            msg.sender,
            abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
            pythData
        );
        if (output < minOutput) revert UnifiedRouter__OutputTooLow();
    }

    /// @notice Sell stock for dUSD (exact output)
    function sellExactOutput(
        address token,
        uint256 exactOutput,
        uint256 maxInput,
        uint256 deadline,
        bytes[] calldata pythData
    ) external payable checkDeadline(deadline) nonReentrant {
        DclexPool pool = _getDclexPool(token);
        uint256 input = pool.swapExactOutput{value: msg.value}(
            false,
            exactOutput,
            msg.sender,
            abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
            pythData
        );
        if (input > maxInput) revert UnifiedRouter__InputTooHigh();
    }

    // ============ Cross-Pool Swap Functions ============

    /// @notice Swap any token for any token (exact input)
    /// @dev Routes through dUSD as hub
    function swapExactInput(
        address inputToken,
        address outputToken,
        uint256 exactInput,
        uint256 minOutput,
        uint256 deadline,
        bytes[] calldata pythData
    ) external payable checkDeadline(deadline) nonReentrant {
        uint256 dUsdAmount;
        uint256 output;

        // Step 1: Convert input to dUSD
        if (inputToken == address(dUSD)) {
            dUsdAmount = exactInput;
            dUSD.safeTransferFrom(msg.sender, address(this), exactInput);
        } else if (inputToken == address(0) || inputToken == wdel) {
            // Native token - swap via V3 WDEL/dUSD pool
            dUsdAmount = _swapV3ExactInput(wdel, address(dUSD), exactInput, address(this), msg.sender);
        } else {
            dUsdAmount = _swapToDusd(inputToken, exactInput, pythData);
        }

        // Step 2: Convert dUSD to output
        if (outputToken == address(dUSD)) {
            output = dUsdAmount;
            dUSD.safeTransfer(msg.sender, output);
        } else if (outputToken == address(0) || outputToken == wdel) {
            // Native token - swap via V3 dUSD/WDEL pool
            output = _swapV3ExactInput(address(dUSD), wdel, dUsdAmount, msg.sender, address(this));
        } else {
            output = _swapFromDusd(outputToken, dUsdAmount, pythData);
        }

        if (output < minOutput) revert UnifiedRouter__OutputTooLow();
        _refundEth();
    }

    /// @notice Swap any token for any token (exact output)
    function swapExactOutput(
        address inputToken,
        address outputToken,
        uint256 exactOutput,
        uint256 maxInput,
        uint256 deadline,
        bytes[] calldata pythData
    ) external payable checkDeadline(deadline) nonReentrant {
        uint256 dUsdNeeded;
        uint256 inputUsed;

        // Calculate dUSD needed for output
        if (outputToken == address(dUSD)) {
            dUsdNeeded = exactOutput;
        } else if (outputToken == address(0) || outputToken == wdel) {
            dUsdNeeded = _quoteV3ExactOutput(address(dUSD), wdel, exactOutput);
        } else {
            dUsdNeeded = _quoteDusdForOutput(outputToken, exactOutput);
        }

        // Get dUSD from input
        if (inputToken == address(dUSD)) {
            inputUsed = dUsdNeeded;
            dUSD.safeTransferFrom(msg.sender, address(this), dUsdNeeded);
        } else if (inputToken == address(0) || inputToken == wdel) {
            inputUsed = _swapV3ExactOutput(wdel, address(dUSD), dUsdNeeded, address(this), msg.sender);
        } else {
            inputUsed = _swapToDusdExactOutput(inputToken, dUsdNeeded, maxInput, pythData);
        }

        if (inputUsed > maxInput) revert UnifiedRouter__InputTooHigh();

        // Convert dUSD to output
        if (outputToken == address(dUSD)) {
            dUSD.safeTransfer(msg.sender, exactOutput);
        } else if (outputToken == address(0) || outputToken == wdel) {
            _swapV3ExactInput(address(dUSD), wdel, dUsdNeeded, msg.sender, address(this));
        } else {
            _swapFromDusd(outputToken, dUsdNeeded, pythData);
        }

        _refundEth();
    }

    // ============ Callbacks ============

    /// @notice Callback from DclexPool
    function dclexSwapCallback(
        address token,
        uint256 amount,
        bytes calldata callbackData
    ) external {
        if (!_validDclexPools[msg.sender]) revert UnifiedRouter__NotDclexPool();

        DclexSwapCallbackData memory data = abi.decode(callbackData, (DclexSwapCallbackData));

        if (data.payWithCrossPoolSwap) {
            // Cross-pool swap: get tokens from another pool
            uint256 inputAmount;
            if (data.inputToken == address(0) || data.inputToken == wdel) {
                inputAmount = _swapV3ExactOutput(wdel, token, amount, msg.sender, data.payer);
            } else {
                inputAmount = _getDclexPool(data.inputToken).swapExactOutput(
                    false,
                    amount,
                    msg.sender,
                    abi.encode(DclexSwapCallbackData(data.payer, false, address(0), 0)),
                    new bytes[](0)
                );
            }
            if (inputAmount > data.maxInputAmount) revert UnifiedRouter__InputTooHigh();
        } else {
            // Simple transfer
            if (data.payer == address(this)) {
                IERC20(token).safeTransfer(msg.sender, amount);
            } else {
                IERC20(token).safeTransferFrom(data.payer, msg.sender, amount);
            }
        }
    }

    /// @notice Callback from V3Pool
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        if (!_validV3Pools[msg.sender]) revert UnifiedRouter__NotV3Pool();

        V3CallbackData memory cbData = abi.decode(data, (V3CallbackData));

        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        address tokenToPay = amount0Delta > 0 ? cbData.tokenIn : cbData.tokenOut;

        if (cbData.payer == address(this)) {
            IERC20(tokenToPay).safeTransfer(msg.sender, amountToPay);
        } else {
            IERC20(tokenToPay).safeTransferFrom(cbData.payer, msg.sender, amountToPay);
        }
    }

    // ============ Internal Functions ============

    function _swapToDusd(
        address token,
        uint256 amount,
        bytes[] calldata pythData
    ) internal returns (uint256) {
        // Check if token has a DclexPool
        DclexPool dclexPool = dclexPools[token];
        if (address(dclexPool) != address(0)) {
            return dclexPool.swapExactInput{value: msg.value}(
                false,
                amount,
                address(this),
                abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
                pythData
            );
        }

        // Check if token has a V3Pool
        address v3Pool = v3Pools[token];
        if (v3Pool != address(0)) {
            return _swapV3ExactInput(token, address(dUSD), amount, address(this), msg.sender);
        }

        revert UnifiedRouter__UnknownToken();
    }

    function _swapFromDusd(
        address token,
        uint256 dUsdAmount,
        bytes[] calldata pythData
    ) internal returns (uint256) {
        // Check if token has a DclexPool
        DclexPool dclexPool = dclexPools[token];
        if (address(dclexPool) != address(0)) {
            return dclexPool.swapExactInput(
                true,
                dUsdAmount,
                msg.sender,
                abi.encode(DclexSwapCallbackData(address(this), false, address(0), 0)),
                pythData
            );
        }

        // Check if token has a V3Pool
        address v3Pool = v3Pools[token];
        if (v3Pool != address(0)) {
            return _swapV3ExactInput(address(dUSD), token, dUsdAmount, msg.sender, address(this));
        }

        revert UnifiedRouter__UnknownToken();
    }

    function _swapToDusdExactOutput(
        address token,
        uint256 dUsdAmount,
        uint256 maxInput,
        bytes[] calldata pythData
    ) internal returns (uint256) {
        // Check if token has a DclexPool
        DclexPool dclexPool = dclexPools[token];
        if (address(dclexPool) != address(0)) {
            return dclexPool.swapExactOutput{value: msg.value}(
                false,
                dUsdAmount,
                address(this),
                abi.encode(DclexSwapCallbackData(msg.sender, false, address(0), 0)),
                pythData
            );
        }

        // Check if token has a V3Pool
        address v3Pool = v3Pools[token];
        if (v3Pool != address(0)) {
            return _swapV3ExactOutput(token, address(dUSD), dUsdAmount, address(this), msg.sender);
        }

        revert UnifiedRouter__UnknownToken();
    }

    function _swapV3ExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        address payer
    ) internal returns (uint256) {
        return _executeV3Swap(tokenIn, tokenOut, int256(amountIn), recipient, payer);
    }

    function _swapV3ExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        address recipient,
        address payer
    ) internal returns (uint256) {
        return _executeV3Swap(tokenIn, tokenOut, -int256(amountOut), recipient, payer);
    }

    function _executeV3Swap(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        address recipient,
        address payer
    ) private returns (uint256) {
        address pool = _getV3Pool(tokenIn, tokenOut);
        bool zeroForOne = tokenIn < tokenOut;
        uint160 sqrtPriceLimit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        bytes memory cbData = _encodeV3CallbackData(tokenIn, tokenOut, payer);

        (int256 amount0, int256 amount1) = IUniswapV3Pool(pool).swap(
            recipient,
            zeroForOne,
            amountSpecified,
            sqrtPriceLimit,
            cbData
        );

        // For exact input (positive amountSpecified): return output amount (negative)
        // For exact output (negative amountSpecified): return input amount (positive)
        if (amountSpecified > 0) {
            return uint256(zeroForOne ? -amount1 : -amount0);
        } else {
            return uint256(zeroForOne ? amount0 : amount1);
        }
    }

    function _encodeV3CallbackData(
        address tokenIn,
        address tokenOut,
        address payer
    ) private pure returns (bytes memory) {
        return abi.encode(V3CallbackData({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: DEFAULT_FEE,
            payer: payer
        }));
    }

    function _quoteV3ExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    ) internal view returns (uint256) {
        // Simplified quote - in production, use Quoter contract
        // This is a rough estimate based on current price
        address pool = _getV3Pool(tokenIn, tokenOut);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        bool zeroForOne = tokenIn < tokenOut;
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 192);

        if (zeroForOne) {
            return amountOut * 1e18 / price;
        } else {
            return amountOut * price / 1e18;
        }
    }

    function _quoteDusdForOutput(
        address token,
        uint256 outputAmount
    ) internal view returns (uint256) {
        // Simplified quote for DclexPool - actual implementation would use pool's oracle
        // For V3Pool, use the V3 quoter
        address v3Pool = v3Pools[token];
        if (v3Pool != address(0)) {
            return _quoteV3ExactOutput(address(dUSD), token, outputAmount);
        }
        // For DclexPool, return a rough estimate (actual calculation needs oracle)
        return outputAmount; // 1:1 estimate
    }

    function _getV3Pool(address tokenA, address tokenB) internal view returns (address) {
        // First check if either token has a registered V3 pool
        address pool = v3Pools[tokenA];
        if (pool != address(0)) return pool;

        pool = v3Pools[tokenB];
        if (pool != address(0)) return pool;

        // Fall back to factory lookup
        pool = v3Factory.getPool(tokenA, tokenB, DEFAULT_FEE);
        if (pool == address(0)) revert UnifiedRouter__UnknownToken();
        return pool;
    }

    function _getDclexPool(address token) internal view returns (DclexPool) {
        DclexPool pool = dclexPools[token];
        if (address(pool) == address(0)) revert UnifiedRouter__UnknownToken();
        return pool;
    }

    function _removeStockToken(address token) internal {
        for (uint256 i = 0; i < stockTokens.length; ++i) {
            if (stockTokens[i] == token) {
                stockTokens[i] = stockTokens[stockTokens.length - 1];
                stockTokens.pop();
                break;
            }
        }
    }

    function _refundEth() internal {
        if (address(this).balance > 0) {
            (bool success,) = msg.sender.call{value: address(this).balance}("");
            if (!success) revert UnifiedRouter__NativeTransferFailed();
        }
    }
}
