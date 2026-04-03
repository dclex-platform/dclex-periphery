// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

interface IDclexRouter {
    function stockTokenToPool(address token) external view returns (address);
}

/// @title BatchPoolInitializer
/// @notice Initializes all DclexPools with liquidity in a single transaction
/// @dev Requires DEFAULT_ADMIN_ROLE on Factory and DigitalIdentity to mint tokens
contract BatchPoolInitializer {
    // Local Anvil constants
    uint256 constant STOCK_AMOUNT = 1000e18; // 1000 stock tokens (18 decimals)
    uint256 constant USDC_AMOUNT = 10_000e6; // 10,000 USDC (6 decimals)
    int64 constant MOCK_PRICE = 1_000_000_000; // $10 with expo -8
    int32 constant EXPO = -8;

    /// @notice Initialize all pools with liquidity
    /// @dev Caller must grant DEFAULT_ADMIN_ROLE on Factory and DigitalIdentity first
    /// @param factory The Factory contract (must have DEFAULT_ADMIN_ROLE)
    /// @param router The DclexRouter contract
    /// @param mockPyth The MockPyth contract for price data
    /// @param symbols Array of stock symbols
    /// @param priceFeedIds Array of Pyth price feed IDs (same order as symbols)
    function initializeAllPools(
        Factory factory,
        address router,
        address mockPyth,
        string[] calldata symbols,
        bytes32[] calldata priceFeedIds
    ) external payable {
        require(symbols.length == priceFeedIds.length, "Length mismatch");

        IDclexRouter _router = IDclexRouter(router);
        DigitalIdentity digitalIdentity = DigitalIdentity(address(factory.getDID()));

        // Ensure this contract has DID for receiving and sending tokens
        if (digitalIdentity.balanceOf(address(this)) == 0) {
            digitalIdentity.mintAdmin(address(this), 2, bytes32(0));
        }

        // Calculate fee per pool
        bytes[] memory sampleData = new bytes[](1);
        sampleData[0] = MockPyth(mockPyth).createPriceFeedUpdateData(
            bytes32(0), MOCK_PRICE, 10, EXPO, MOCK_PRICE, 10,
            uint64(block.timestamp), uint64(block.timestamp)
        );
        uint256 feePerPool = MockPyth(mockPyth).getUpdateFee(sampleData);

        for (uint256 i = 0; i < symbols.length; i++) {
            address stockAddress = factory.stocks(symbols[i]);
            if (stockAddress == address(0)) continue;

            address poolAddress = _router.stockTokenToPool(stockAddress);
            if (poolAddress == address(0)) continue;

            // Skip if already initialized
            if (IERC20(stockAddress).balanceOf(poolAddress) > 0) continue;

            _initializePool(
                factory,
                digitalIdentity,
                mockPyth,
                symbols[i],
                stockAddress,
                poolAddress,
                priceFeedIds[i],
                feePerPool
            );
        }

        // Refund excess ETH
        if (address(this).balance > 0) {
            payable(msg.sender).transfer(address(this).balance);
        }
    }

    function _initializePool(
        Factory factory,
        DigitalIdentity digitalIdentity,
        address mockPyth,
        string memory symbol,
        address stockAddress,
        address poolAddress,
        bytes32 priceFeedId,
        uint256 pythFee
    ) internal {
        DclexPool pool = DclexPool(poolAddress);
        address usdcAddress = address(pool.usdcToken());

        // Mint DID for pool if needed (allows pool to hold stock tokens)
        if (digitalIdentity.balanceOf(poolAddress) == 0) {
            digitalIdentity.mintAdmin(poolAddress, 2, bytes32(0));
        }

        // Create mock price update data
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[0] = MockPyth(mockPyth).createPriceFeedUpdateData(
            priceFeedId,
            MOCK_PRICE,
            10,
            EXPO,
            MOCK_PRICE,
            10,
            uint64(block.timestamp),
            uint64(block.timestamp)
        );

        // Mint tokens to this contract
        USDCMock(usdcAddress).mint(address(this), USDC_AMOUNT);
        factory.forceMintStocks(symbol, address(this), STOCK_AMOUNT);

        // Approve and initialize
        IERC20(stockAddress).approve(poolAddress, STOCK_AMOUNT);
        IERC20(usdcAddress).approve(poolAddress, USDC_AMOUNT);
        pool.initialize{value: pythFee}(STOCK_AMOUNT, USDC_AMOUNT, priceUpdateData);
    }

    receive() external payable {}
}
