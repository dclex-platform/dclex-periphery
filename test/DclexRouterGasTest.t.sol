// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DclexPythMock} from "dclex-protocol/test/PythMock.sol";
import {DclexRouter} from "../src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IFactory} from "dclex-blockchain/contracts/interfaces/IFactory.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {SmartcontractIdentity} from "dclex-blockchain/contracts/dclex/SmartcontractIdentity.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DclexRouterGasTest is Test, Deployers {
    bytes32 internal constant AAPL_PRICE_FEED_ID = bytes32(uint256(0x1));
    bytes32 internal constant NVDA_PRICE_FEED_ID = bytes32(uint256(0x2));
    bytes32 internal constant USDC_PRICE_FEED_ID = bytes32(uint256(0x3));
    address private immutable ADMIN = makeAddr("admin");
    address private immutable MASTER_ADMIN = makeAddr("master_admin");
    address private immutable POOL_ADMIN = makeAddr("pool_admin");
    PoolKey private ethUsdcPoolKey;
    DigitalIdentity internal digitalIdentity;
    SmartcontractIdentity internal contractIdentity;
    Stock internal aaplStock;
    Stock internal nvdaStock;
    USDCMock internal usdcToken;
    Factory private stocksFactory;
    DclexPythMock private pythMock;
    DclexRouter private dclexRouter;
    DclexPool private aaplPool;
    DclexPool internal nvdaPool;

    function setUp() public {
        usdcToken = new USDCMock("USDC", "USD Coin");
        pythMock = new DclexPythMock();
        vm.deal(address(pythMock), 1 ether);
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(NVDA_PRICE_FEED_ID, 30 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(
            ADMIN,
            MASTER_ADMIN
        );
        digitalIdentity = contracts.digitalIdentity;
        contractIdentity = contracts.contractIdentity;
        stocksFactory = contracts.stocksFactory;
        vm.startPrank(ADMIN);
        stocksFactory.createStocks("Apple", "AAPL");
        stocksFactory.createStocks("NVIDIA", "NVDA");
        vm.stopPrank();
        aaplStock = Stock(contracts.stocksFactory.stocks("AAPL"));
        nvdaStock = Stock(contracts.stocksFactory.stocks("NVDA"));
        aaplPool = new DclexPool(
            IFactory(address(stocksFactory)),
            pythMock.getPyth(),
            aaplStock,
            usdcToken,
            AAPL_PRICE_FEED_ID,
            USDC_PRICE_FEED_ID,
            POOL_ADMIN
        );
        nvdaPool = new DclexPool(
            IFactory(address(stocksFactory)),
            pythMock.getPyth(),
            nvdaStock,
            usdcToken,
            NVDA_PRICE_FEED_ID,
            USDC_PRICE_FEED_ID,
            POOL_ADMIN
        );
        vm.prank(ADMIN);
        contractIdentity.mintAdmin(address(aaplPool));
        vm.prank(ADMIN);
        contractIdentity.mintAdmin(address(nvdaPool));
        setupAccount(address(this));
        aaplPool.initialize(100 ether, 2000e6, new bytes[](0));
        nvdaPool.initialize(100 ether, 2000e6, new bytes[](0));
        setupUniswapV4();
        dclexRouter = new DclexRouter(manager, ethUsdcPoolKey, ADMIN);
        vm.startPrank(ADMIN);
        dclexRouter.setPool(address(aaplStock), aaplPool);
        dclexRouter.setPool(address(nvdaStock), nvdaPool);
        vm.stopPrank();
        vm.startPrank(address(this));
        aaplStock.approve(address(dclexRouter), 100000 ether);
        nvdaStock.approve(address(dclexRouter), 100000 ether);
        usdcToken.approve(address(dclexRouter), 100000 ether);
        vm.stopPrank();
    }

    function setupAccount(address account) private {
        usdcToken.mint(account, 1000000e6);
        vm.prank(ADMIN);
        if (account.code.length == 0) {
            digitalIdentity.mintAdmin(account, 0, "");
        } else {
            contractIdentity.mintAdmin(account);
        }
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
        deployFreshManagerAndRouters();
        Currency ethCurrency = Currency.wrap(address(0));
        Currency usdcCurrency = Currency.wrap(address(usdcToken));
        (ethUsdcPoolKey, ) = initPool(
            ethCurrency,
            usdcCurrency,
            IHooks(address(0)),
            3000,
            4339505179874779662909440
        );
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
            ZERO_BYTES
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
