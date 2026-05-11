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

    /// @notice Override _mint to verify DID   
    function _mint(address to, uint256 tokenId) internal override {
        if (!did.isValid(did.getId(to))) {
                revert DclexPositionManager__TransferNotAllowed();
        }
        super._mint(to, tokenId);
    }

    /// @notice Override _transfer to verify DID
    function _transfer(address from, address to, uint256 tokenId) internal override {
        if (!did.verifyTransfer(from, to)) {
            revert DclexPositionManager__TransferNotAllowed();
        }
        super._transfer(from, to, tokenId);
    }
}
