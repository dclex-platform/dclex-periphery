// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {UniswapV3Pool} from "@uniswap/v3-core/contracts/UniswapV3Pool.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

/// @title PoolInitCodeHash guard
/// @notice Fails loudly when the periphery's hardcoded POOL_INIT_CODE_HASH
/// drifts from the actual compiled `UniswapV3Pool` creation code. Every
/// consumer of `PoolAddress.computeAddress` (NonfungiblePositionManager,
/// SwapRouter, Quoter) will compute the wrong pool address if these two
/// diverge — mints/swaps/quotes then hit a `0x` revert because the
/// "computed" pool has no code.
///
/// Bump v3-core, change solc version, flip optimizer settings, etc.: this
/// test catches it in CI instead of at runtime on-chain.
contract PoolInitCodeHashTest is Test {
    function test_pool_init_code_hash_matches_compiled_bytecode() public pure {
        bytes32 actual = keccak256(type(UniswapV3Pool).creationCode);
        assertEq(
            actual,
            PoolAddress.POOL_INIT_CODE_HASH,
            "PoolAddress.POOL_INIT_CODE_HASH is stale. Update lib/v3-periphery/contracts/libraries/PoolAddress.sol to the new keccak256(type(UniswapV3Pool).creationCode)."
        );
    }
}
