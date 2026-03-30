// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    NonfungiblePositionManager
} from "@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol";
import {
    IDID
} from "dclex-blockchain/contracts/interfaces/IDID.sol";

/// @title DclexPositionManager
/// @notice Extends NonfungiblePositionManager with DID verification on NFT transfers.
/// Only addresses with valid DID can hold V3 liquidity position NFTs.
/// Mints and burns are exempt (from=0 or to=0).
contract DclexPositionManager is NonfungiblePositionManager {
    IDID public immutable did;

    error DclexPositionManager__TransferNotAllowed();

    constructor(
        address _factory,
        address _WETH9,
        address _tokenDescriptor,
        IDID _did
    ) NonfungiblePositionManager(_factory, _WETH9, _tokenDescriptor) {
        did = _did;
    }

    /// @notice Override _update to verify DID on transfers (not mints/burns)
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address from) {
        from = super._update(to, tokenId, auth);

        // Skip DID check for mints (from=0) and burns (to=0)
        if (from != address(0) && to != address(0)) {
            if (!did.verifyTransfer(from, to)) {
                revert DclexPositionManager__TransferNotAllowed();
            }
        }
    }
}
