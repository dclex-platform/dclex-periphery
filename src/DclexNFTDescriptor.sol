// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {
    INonfungibleTokenPositionDescriptor
} from "@uniswap/v3-periphery/contracts/interfaces/INonfungibleTokenPositionDescriptor.sol";
import {
    INonfungiblePositionManager
} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

/// @title DclexNFTDescriptor
/// @notice Resolves V3 LP position NFT metadata to a backend-rendered URL.
///
/// `tokenURI(positionManager, tokenId)` returns `{baseURI}{tokenId}` —
/// the backend (`/nft/positions/<id>/`) serves the ERC-721 JSON, which in
/// turn references a dynamically-rendered image. Keeping all rendering off
/// chain means we can iterate on the card design (colors, layout, copy)
/// without ever touching the contract.
///
/// `baseURI` is mutable behind `onlyOwner` so an env-config rotation
/// (dev -> staging -> prod) doesn't require redeploying the descriptor.
/// The `BaseURISet` event lets indexers detect rotations.
contract DclexNFTDescriptor is INonfungibleTokenPositionDescriptor, Ownable {
    using Strings for uint256;

    string public baseURI;

    event BaseURISet(string oldBaseURI, string newBaseURI);

    error InvalidBaseURI();

    constructor(string memory _baseURI) Ownable(msg.sender) {
        _requireValidBaseURI(_baseURI);
        baseURI = _baseURI;
        emit BaseURISet("", _baseURI);
    }

    /// @notice Update the URL prefix used by `tokenURI`. Must be
    /// non-empty and end with a `/` so the appended `tokenId` lands on a
    /// path segment, not glued onto whatever the prefix happens to end
    /// with.
    function setBaseURI(string calldata _baseURI) external onlyOwner {
        _requireValidBaseURI(_baseURI);
        emit BaseURISet(baseURI, _baseURI);
        baseURI = _baseURI;
    }

    /// @inheritdoc INonfungibleTokenPositionDescriptor
    /// @dev `positionManager` is intentionally ignored — every Dclex deployment
    ///      runs a single NPM, and the backend looks up positions by id alone.
    ///      The trailing `/` matches Django's `APPEND_SLASH` route shape so
    ///      MetaMask / OpenSea hit the canonical URL directly instead of a
    ///      301 redirect (some clients don't follow redirects consistently).
    function tokenURI(
        INonfungiblePositionManager /* positionManager */,
        uint256 tokenId
    ) external view override returns (string memory) {
        return string.concat(baseURI, tokenId.toString(), "/");
    }

    function _requireValidBaseURI(string memory _baseURI) internal pure {
        bytes memory b = bytes(_baseURI);
        if (b.length == 0 || b[b.length - 1] != "/") revert InvalidBaseURI();
    }
}
