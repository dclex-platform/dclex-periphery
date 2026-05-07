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
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";

contract HelperConfig is Script {
    error HelperConfig__InvalidChainId();
    error HelperConfig__DusdNotRegistered();

    string internal constant DUSD_SYMBOL = "dUSD";

    struct NetworkConfig {
        ISwapRouter v3SwapRouter;
        IQuoter v3Quoter;
        IERC20 dusdToken;
        address admin;
    }

    /// @notice Resolve dUSD via Factory.stablecoins("dUSD"). Reverts if
    ///         the Factory hasn't created dUSD yet — staging/prod must run
    ///         DeployProduction (which calls createStablecoin) before any
    ///         pool / router deploy that needs dUSD.
    function getDusdFromFactory(Factory factory) public view returns (IERC20) {
        address dusd = factory.stablecoins(DUSD_SYMBOL);
        if (dusd == address(0)) revert HelperConfig__DusdNotRegistered();
        return IERC20(dusd);
    }

    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant PRIMEDELTA_DEV_CHAIN_ID = 2028;
    uint256 public constant PRIMEDELTA_TESTNET_CHAIN_ID = 7357;

    NetworkConfig public localNetworkConfig;
    NetworkConfig public primedeltaDevNetworkConfig;
    NetworkConfig public primedeltaTestnetNetworkConfig;

    function getConfig(IERC20 dusdToken) public returns (NetworkConfig memory) {
        if (block.chainid == LOCAL_CHAIN_ID) {
            return getLocalConfig(dusdToken);
        } else if (block.chainid == PRIMEDELTA_DEV_CHAIN_ID) {
            return getPrimedeltaDevConfig(dusdToken);
        } else if (block.chainid == PRIMEDELTA_TESTNET_CHAIN_ID) {
            return getPrimedeltaTestnetConfig(dusdToken);
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getPrimedeltaDevConfig(
        IERC20 dusdToken
    ) public returns (NetworkConfig memory) {
        if (primedeltaDevNetworkConfig.admin != address(0)) {
            return primedeltaDevNetworkConfig;
        }

        primedeltaDevNetworkConfig = NetworkConfig({
            v3SwapRouter: ISwapRouter(address(0)),
            v3Quoter: IQuoter(address(0)),
            dusdToken: dusdToken,
            admin: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        });
        return primedeltaDevNetworkConfig;
    }

    function getPrimedeltaTestnetConfig(
        IERC20 dusdToken
    ) public returns (NetworkConfig memory) {
        if (primedeltaTestnetNetworkConfig.admin != address(0)) {
            return primedeltaTestnetNetworkConfig;
        }

        primedeltaTestnetNetworkConfig = NetworkConfig({
            v3SwapRouter: ISwapRouter(address(0)),
            v3Quoter: IQuoter(address(0)),
            dusdToken: dusdToken,
            admin: vm.envAddress("DCLEX_ADMIN")
        });
        return primedeltaTestnetNetworkConfig;
    }

    function getLocalConfig(
        IERC20 dusdToken
    ) public returns (NetworkConfig memory) {
        if (localNetworkConfig.admin != address(0)) {
            return localNetworkConfig;
        }

        localNetworkConfig = NetworkConfig({
            v3SwapRouter: ISwapRouter(address(0)),
            v3Quoter: IQuoter(address(0)),
            dusdToken: dusdToken,
            admin: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        });
        return localNetworkConfig;
    }
}
