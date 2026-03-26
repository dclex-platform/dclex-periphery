// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {
    ISwapRouter
} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {
    IQuoter
} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HelperConfig is Script {
    error HelperConfig__InvalidChainId();

    struct NetworkConfig {
        ISwapRouter v3SwapRouter;
        IQuoter v3Quoter;
        IERC20 usdcToken;
        address admin;
    }

    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant PRIMELTA_DEV_CHAIN_ID = 2028;

    NetworkConfig public localNetworkConfig;
    NetworkConfig public primeltaDevNetworkConfig;

    function getConfig(IERC20 usdcToken) public returns (NetworkConfig memory) {
        if (block.chainid == LOCAL_CHAIN_ID) {
            return getLocalConfig(usdcToken);
        } else if (block.chainid == PRIMELTA_DEV_CHAIN_ID) {
            return getPrimeltaDevConfig(usdcToken);
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getPrimeltaDevConfig(
        IERC20 usdcToken
    ) public returns (NetworkConfig memory) {
        if (address(primeltaDevNetworkConfig.v3SwapRouter) != address(0)) {
            return primeltaDevNetworkConfig;
        }

        // V3 infrastructure addresses for Primelta dev chain
        // These will be deployed by DeployV3Infrastructure script
        primeltaDevNetworkConfig = NetworkConfig({
            v3SwapRouter: ISwapRouter(address(0)),
            v3Quoter: IQuoter(address(0)),
            usdcToken: usdcToken,
            admin: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        });
        return primeltaDevNetworkConfig;
    }

    function getLocalConfig(
        IERC20 usdcToken
    ) public returns (NetworkConfig memory) {
        if (address(localNetworkConfig.v3SwapRouter) != address(0)) {
            return localNetworkConfig;
        }

        // For local testing, these will be deployed by test setup
        // Use Anvil account #1 as admin (same as ADMIN_KEY in deploy script)
        localNetworkConfig = NetworkConfig({
            v3SwapRouter: ISwapRouter(address(0)),
            v3Quoter: IQuoter(address(0)),
            usdcToken: usdcToken,
            admin: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        });
        return localNetworkConfig;
    }
}
