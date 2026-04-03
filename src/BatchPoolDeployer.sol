// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DclexRouter} from "./DclexRouter.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";

/// @title BatchPoolDeployer
/// @notice Deploys all DclexPools in a single transaction
/// @dev Requires temporary ownership of router and DEFAULT_ADMIN_ROLE on DigitalIdentity
contract BatchPoolDeployer {
    /// @notice Deploy pools for all stocks and register them with router
    /// @dev Caller must transfer router ownership to this contract first,
    ///      and grant DEFAULT_ADMIN_ROLE on DigitalIdentity to this contract.
    ///      After calling, ownership is transferred to finalOwner.
    /// @param router The DclexRouter to register pools with (must be owned by this contract)
    /// @param factory The Factory contract (for DID access)
    /// @param usdcToken The USDC token for pools
    /// @param oracle The price oracle for pools
    /// @param stockAddresses Array of stock token addresses
    /// @param priceFeedIds Array of Pyth price feed IDs (same order as stocks)
    /// @param maxPriceStaleness Max price staleness in seconds
    /// @param finalOwner Address to receive router ownership after deployment
    function deployAllPools(
        DclexRouter router,
        Factory factory,
        IERC20 usdcToken,
        IPriceOracle oracle,
        address[] calldata stockAddresses,
        bytes32[] calldata priceFeedIds,
        uint256 maxPriceStaleness,
        address finalOwner
    ) external {
        require(stockAddresses.length == priceFeedIds.length, "Length mismatch");

        DigitalIdentity digitalIdentity = DigitalIdentity(address(factory.getDID()));

        // Mint DID for router
        digitalIdentity.mintAdmin(address(router), 2, bytes32(0));

        for (uint256 i = 0; i < stockAddresses.length; i++) {
            address stockAddress = stockAddresses[i];
            if (stockAddress == address(0)) continue;

            // Deploy pool with finalOwner as admin
            DclexPool pool = new DclexPool(
                IStock(stockAddress),
                usdcToken,
                oracle,
                priceFeedIds[i],
                finalOwner,
                maxPriceStaleness
            );

            // Register with router (we have ownership)
            router.setPool(stockAddress, pool);

            // Mint DID for pool
            digitalIdentity.mintAdmin(address(pool), 2, bytes32(0));
        }

        // Transfer router ownership to final owner
        router.transferOwnership(finalOwner);
    }
}
