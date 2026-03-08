// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {USDCMock} from "dclex-mint/contracts/mocks/USDCMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HelperConfig is Script {
    error HelperConfig__InvalidChainId();

    struct NetworkConfig {
        PoolManager uniswapV4PoolManager;
        PoolKey ethUsdcPoolKey;
        IERC20 usdcToken;
        address admin;
    }

    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant PRIMELTA_DEV_CHAIN_ID = 2028;
    NetworkConfig public localNetworkConfig;
    NetworkConfig public primeltaDevNetworkConfig;

    function getConfig(IERC20 usdcToken) public returns (NetworkConfig memory) {
        if (block.chainid == LOCAL_CHAIN_ID) {
            return getLocalConfig(usdcToken);
        } else if (block.chainid == ETH_SEPOLIA_CHAIN_ID) {
            return getSepoliaConfig(usdcToken);
        } else if (block.chainid == PRIMELTA_DEV_CHAIN_ID) {
            return getPrimeltaDevConfig(usdcToken);
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getSepoliaConfig(
        IERC20 usdcToken
    ) public pure returns (NetworkConfig memory) {
        Currency ethCurrency = Currency.wrap(address(0));
        Currency usdcCurrency = Currency.wrap(address(usdcToken));
        PoolKey memory ethUsdcPoolKey = PoolKey(
            ethCurrency,
            usdcCurrency,
            3000,
            int24((3000 / 100) * 2),
            IHooks(address(0))
        );
        return
            NetworkConfig({
                uniswapV4PoolManager: PoolManager(
                    0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
                ),
                ethUsdcPoolKey: ethUsdcPoolKey,
                usdcToken: usdcToken,
                admin: 0x971b5a2872ec17EeDDED9fc4dd691D8B33B97031
            });
    }

    function getPrimeltaDevConfig(
        IERC20 usdcToken
    ) public returns (NetworkConfig memory) {
        if (address(primeltaDevNetworkConfig.uniswapV4PoolManager) != address(0)) {
            return primeltaDevNetworkConfig;
        }
        Currency ethCurrency = Currency.wrap(address(0));
        Currency usdcCurrency = Currency.wrap(address(usdcToken));
        PoolKey memory ethUsdcPoolKey = PoolKey(
            ethCurrency,
            usdcCurrency,
            3000,
            int24((3000 / 100) * 2),
            IHooks(address(0))
        );
        // Use existing deployed PoolManager — do NOT deploy a new one
        PoolManager manager = PoolManager(0x23d351BA89eaAc4E328133Cb48e050064C219A1E);
        primeltaDevNetworkConfig = NetworkConfig({
            uniswapV4PoolManager: manager,
            ethUsdcPoolKey: ethUsdcPoolKey,
            usdcToken: usdcToken,
            admin: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        });
        return primeltaDevNetworkConfig;
    }

    function getLocalConfig(
        IERC20 usdcToken
    ) public returns (NetworkConfig memory) {
        if (address(localNetworkConfig.uniswapV4PoolManager) != address(0)) {
            return localNetworkConfig;
        }
        address admin = makeAddr("admin");
        Currency ethCurrency = Currency.wrap(address(0));
        Currency usdcCurrency = Currency.wrap(address(usdcToken));
        PoolManager manager = new PoolManager(address(this));
        PoolKey memory ethUsdcPoolKey = PoolKey(
            ethCurrency,
            usdcCurrency,
            3000,
            int24((3000 / 100) * 2),
            IHooks(address(0))
        );
        localNetworkConfig = NetworkConfig({
            uniswapV4PoolManager: manager,
            ethUsdcPoolKey: ethUsdcPoolKey,
            usdcToken: usdcToken,
            admin: admin
        });
        return localNetworkConfig;
    }
}
