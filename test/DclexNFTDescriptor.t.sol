// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DclexNFTDescriptor} from "src/DclexNFTDescriptor.sol";
import {
    INonfungiblePositionManager
} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

contract DclexNFTDescriptorTest is Test {
    DclexNFTDescriptor descriptor;
    address owner = address(0xABCD);
    address other = address(0xBEEF);

    string constant INITIAL = "https://api-dev.primedelta.io/nft/positions/";

    function setUp() public {
        vm.prank(owner);
        descriptor = new DclexNFTDescriptor(INITIAL);
    }

    function test_constructor_sets_owner_and_base_uri() public view {
        assertEq(descriptor.owner(), owner);
        assertEq(descriptor.baseURI(), INITIAL);
    }

    function test_tokenURI_concatenates_base_and_id() public view {
        // positionManager is ignored by the descriptor — pass a dummy
        INonfungiblePositionManager npm = INonfungiblePositionManager(address(0xDEAD));
        assertEq(
            descriptor.tokenURI(npm, 13),
            string.concat(INITIAL, "13")
        );
        assertEq(
            descriptor.tokenURI(npm, 0),
            string.concat(INITIAL, "0")
        );
        // Large ids stringify without truncation.
        assertEq(
            descriptor.tokenURI(npm, 12345678901234567890),
            string.concat(INITIAL, "12345678901234567890")
        );
    }

    function test_setBaseURI_updates_value_and_emits() public {
        string memory next = "https://api.primedelta.io/nft/positions/";
        vm.expectEmit(true, true, true, true, address(descriptor));
        emit DclexNFTDescriptor.BaseURISet(INITIAL, next);
        vm.prank(owner);
        descriptor.setBaseURI(next);
        assertEq(descriptor.baseURI(), next);
    }

    function test_setBaseURI_reverts_for_non_owner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                other
            )
        );
        vm.prank(other);
        descriptor.setBaseURI("https://evil.example/");
        // value unchanged
        assertEq(descriptor.baseURI(), INITIAL);
    }
}
