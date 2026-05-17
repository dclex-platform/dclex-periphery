// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DclexRouter} from "./DclexRouter.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title BatchPoolDeployer
/// @notice Deploys all DclexPools in a single transaction
/// @dev Requires temporary ownership of router and DEFAULT_ADMIN_ROLE on DigitalIdentity
contract BatchPoolDeployer {
    /// @notice Default base fee rate applied to every newly-deployed pool (3%)
    /// @dev When the pool is perfectly balanced the effective fee equals this value
    uint256 public constant DEFAULT_BASE_FEE_RATE = 0.01 ether;
    /// @notice Default sensitivity parameter (0.1%) controlling how fast the fee rises
    /// with pool imbalance. feeCurveA = sensitivity / 4, feeCurveB = baseFeeRate - sensitivity.
    uint256 public constant DEFAULT_SENSITIVITY = 0.001 ether;

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    struct DeployParams {
        DclexRouter router;
        Factory factory;
        IERC20 usdcToken;
        IPriceOracle oracle;
        address[] stockAddresses;
        bytes32[] priceFeedIds;
        uint256 maxPriceStaleness;
        address finalOwner;
    }

    function deployAllPools(DeployParams calldata params) external {
        require(params.stockAddresses.length == params.priceFeedIds.length, "Length mismatch");

        DigitalIdentity digitalIdentity = DigitalIdentity(address(params.factory.getDID()));
        digitalIdentity.mintAdmin(address(params.router), 2, bytes32(0));

        uint256 feeCurveA = DEFAULT_SENSITIVITY / 4;
        uint256 feeCurveB = DEFAULT_BASE_FEE_RATE - DEFAULT_SENSITIVITY;

        for (uint256 i = 0; i < params.stockAddresses.length; i++) {
            if (params.stockAddresses[i] == address(0)) continue;

            DclexPool pool = new DclexPool(
                IStock(params.stockAddresses[i]),
                params.usdcToken,
                params.oracle,
                params.priceFeedIds[i],
                params.maxPriceStaleness,
                feeCurveA,
                feeCurveB,
                params.finalOwner
            );

            params.router.setDclexPool(params.stockAddresses[i], pool);
            digitalIdentity.mintAdmin(address(pool), 2, bytes32(0));
        }

        params.router.transferOwnership(params.finalOwner);
    }
}
