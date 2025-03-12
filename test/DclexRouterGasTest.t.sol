// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DclexPythMock} from "dclex-protocol/test/PythMock.sol";
import {DclexRouter} from "../src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {ITransferVerifier} from "dclex-blockchain/contracts/interfaces/ITransferVerifier.sol";
import {DeployRouterWithPools} from "../script/DeployDclexRouterWithPools.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {HelperConfig as DclexProtocolHelperConfig} from "dclex-protocol/script/HelperConfig.s.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IFactory} from "dclex-blockchain/contracts/interfaces/IFactory.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

contract DclexRouterGasTest is Test {
    bytes32 internal AAPL_PRICE_FEED_ID;
    bytes32 internal NVDA_PRICE_FEED_ID;
    bytes32 internal USDC_PRICE_FEED_ID;
    address private immutable ADMIN = makeAddr("admin");
    address private immutable MASTER_ADMIN = makeAddr("master_admin");
    address private immutable POOL_ADMIN = makeAddr("pool_admin");
    PoolKey private ethUsdcPoolKey;
    DigitalIdentity internal digitalIdentity;
    Stock internal aaplStock;
    Stock internal nvdaStock;
    USDCMock internal usdcToken;
    Factory private stocksFactory;
    DclexPythMock private pythMock;
    DclexRouter private dclexRouter;
    DclexPool private aaplPool;
    DclexPool internal nvdaPool;
    PoolManager private manager;
    PoolModifyLiquidityTest private modifyLiquidityRouter;

    receive() external payable {}

    function setUp() public {
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(
            ADMIN,
            MASTER_ADMIN
        );
        digitalIdentity = contracts.digitalIdentity;
        stocksFactory = contracts.stocksFactory;
        vm.startPrank(ADMIN);
        stocksFactory.createStocks("Apple", "AAPL");
        stocksFactory.createStocks("NVIDIA", "NVDA");
        vm.stopPrank();
        aaplStock = Stock(contracts.stocksFactory.stocks("AAPL"));
        nvdaStock = Stock(contracts.stocksFactory.stocks("NVDA"));
        HelperConfig.NetworkConfig memory config;
        DeployRouterWithPools routerDeployer = new DeployRouterWithPools();
        address pythAddress;
        DclexProtocolHelperConfig dclexProtocolHelperConfig;
        (
            dclexRouter,
            config,
            pythAddress,
            dclexProtocolHelperConfig
        ) = routerDeployer.run(stocksFactory);
        usdcToken = USDCMock(address(config.usdcToken));
        manager = config.uniswapV4PoolManager;
        ethUsdcPoolKey = config.ethUsdcPoolKey;
        pythMock = new DclexPythMock(pythAddress);
        vm.deal(address(pythMock), 1 ether);
        AAPL_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("AAPL");
        NVDA_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("NVDA");
        USDC_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("USDC");
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(NVDA_PRICE_FEED_ID, 30 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);
        aaplPool = dclexRouter.stockTokenToPool(address(aaplStock));
        nvdaPool = dclexRouter.stockTokenToPool(address(nvdaStock));
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(
            address(aaplPool),
            0,
            "",
            ITransferVerifier(address(0))
        );
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(
            address(nvdaPool),
            0,
            "",
            ITransferVerifier(address(0))
        );
        setupAccount(address(this));
        aaplPool.initialize(100 ether, 2000e6, new bytes[](0));
        nvdaPool.initialize(100 ether, 2000e6, new bytes[](0));
        setupUniswapV4();
        vm.startPrank(address(this));
        aaplStock.approve(address(dclexRouter), 100000 ether);
        nvdaStock.approve(address(dclexRouter), 100000 ether);
        usdcToken.approve(address(dclexRouter), 100000 ether);
        vm.stopPrank();
    }

    function setupAccount(address account) private {
        usdcToken.mint(account, 1000000e6);
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(
            account,
            0,
            "",
            ITransferVerifier(address(0))
        );
        vm.prank(MASTER_ADMIN);
        stocksFactory.forceMintStocks("AAPL", account, 100000 ether);
        vm.prank(MASTER_ADMIN);
        stocksFactory.forceMintStocks("NVDA", account, 10000 ether);
        vm.startPrank(account);
        aaplStock.approve(address(aaplPool), 100000 ether);
        nvdaStock.approve(address(nvdaPool), 100000 ether);
        usdcToken.approve(address(aaplPool), 100000e6);
        usdcToken.approve(address(nvdaPool), 100000 ether);
        vm.stopPrank();
    }

    function setupUniswapV4() private {
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        (uint256 amount0Delta, ) = LiquidityAmounts.getAmountsForLiquidity(
            4339505179874779662909440,
            TickMath.getSqrtPriceAtTick(-200040),
            TickMath.getSqrtPriceAtTick(-190020),
            0.01 ether
        );
        IPoolManager.ModifyLiquidityParams
            memory addLiquidityParams = IPoolManager.ModifyLiquidityParams({
                tickLower: -200040,
                tickUpper: -190020,
                liquidityDelta: 0.01 ether,
                salt: bytes32(0)
            });
        usdcToken.approve(address(modifyLiquidityRouter), 100000e6);
        modifyLiquidityRouter.modifyLiquidity{value: amount0Delta + 1}(
            ethUsdcPoolKey,
            addLiquidityParams,
            ""
        );
    }

    function testBuyStockExactOutput() external {
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            1000e6,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testSellStockExactOutput() external {
        dclexRouter.sellExactOutput(
            address(aaplStock),
            1e6,
            100 ether,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testBuyStockExactInput() external {
        dclexRouter.buyExactInput(
            address(aaplStock),
            1e6,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testSellStockExactInput() external {
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testStockToStockExactInput() external {
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testEthToStockExactInput() external {
        dclexRouter.swapExactInput{value: 0.1 ether}(
            address(0),
            address(aaplStock),
            0.1 ether,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testStockToEthExactInput() external {
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(0),
            1 ether,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testStockToStockExactOutput() external {
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            type(uint256).max,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testEthToStockExactOutput() external {
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(0),
            address(aaplStock),
            0.1 ether,
            type(uint256).max,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testStockToEthExactOutput() external {
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(0),
            0.1 ether,
            type(uint256).max,
            block.timestamp + 1,
            new bytes[](0)
        );
    }
}
