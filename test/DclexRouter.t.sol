// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DclexPythMock} from "dclex-protocol/test/PythMock.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IFactory} from "dclex-blockchain/contracts/interfaces/IFactory.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {SmartcontractIdentity} from "dclex-blockchain/contracts/dclex/SmartcontractIdentity.sol";
import {TestBalance} from "dclex-protocol/test/TestBalance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DclexRouterTest is Test, TestBalance, Deployers {
    bytes[] internal PYTH_DATA = new bytes[](0);
    bytes32 internal constant AAPL_PRICE_FEED_ID = bytes32(uint256(0x1));
    bytes32 internal constant NVDA_PRICE_FEED_ID = bytes32(uint256(0x2));
    bytes32 internal constant AMZN_PRICE_FEED_ID = bytes32(uint256(0x3));
    bytes32 internal constant USDC_PRICE_FEED_ID = bytes32(uint256(0x4));
    address private immutable ADMIN = makeAddr("admin");
    address private immutable MASTER_ADMIN = makeAddr("master_admin");
    address private immutable POOL_ADMIN = makeAddr("pool_admin");
    address private immutable USER_1 = makeAddr("user_1");
    address private immutable USER_2 = makeAddr("user_2");
    PoolKey private ethUsdcPoolKey;
    DigitalIdentity internal digitalIdentity;
    SmartcontractIdentity internal contractIdentity;
    Stock internal aaplStock;
    Stock internal nvdaStock;
    Stock internal amznStock;
    USDCMock internal usdcToken;
    Factory private stocksFactory;
    DclexPythMock private pythMock;
    DclexRouter private dclexRouter;
    DclexPool private aaplPool;
    DclexPool internal nvdaPool;
    DclexPool internal amznPool;

    event PoolSetForToken(address token, address pool);
    event SwapExecuted(
        bool usdcInput,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 stockPrice,
        uint256 usdcPrice,
        address recipient
    );

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
        stocksFactory.createStocks("Amazon", "AMZN");
        vm.stopPrank();
        aaplStock = Stock(contracts.stocksFactory.stocks("AAPL"));
        nvdaStock = Stock(contracts.stocksFactory.stocks("NVDA"));
        amznStock = Stock(contracts.stocksFactory.stocks("AMZN"));
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
        amznPool = new DclexPool(
            IFactory(address(stocksFactory)),
            pythMock.getPyth(),
            amznStock,
            usdcToken,
            AMZN_PRICE_FEED_ID,
            USDC_PRICE_FEED_ID,
            POOL_ADMIN
        );
        vm.startPrank(ADMIN);
        contractIdentity.mintAdmin(address(aaplPool));
        contractIdentity.mintAdmin(address(nvdaPool));
        contractIdentity.mintAdmin(address(amznPool));
        vm.stopPrank();
        setupAccount(address(this));
        setupAccount(USER_1);
        setupAccount(USER_2);
        aaplPool.initialize(100 ether, 2000e6, PYTH_DATA);
        nvdaPool.initialize(100 ether, 2000e6, PYTH_DATA);
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
        vm.startPrank(USER_1);
        aaplStock.approve(address(dclexRouter), 100000 ether);
        nvdaStock.approve(address(dclexRouter), 100000 ether);
        usdcToken.approve(address(dclexRouter), 100000 ether);
        vm.stopPrank();
        vm.startPrank(USER_2);
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
        vm.startPrank(MASTER_ADMIN);
        stocksFactory.forceMintStocks("AAPL", account, 100000 ether);
        stocksFactory.forceMintStocks("NVDA", account, 10000 ether);
        vm.startPrank(account);
        aaplStock.approve(address(aaplPool), 100000 ether);
        nvdaStock.approve(address(nvdaPool), 100000 ether);
        usdcToken.approve(address(aaplPool), 100000e6);
        usdcToken.approve(address(nvdaPool), 100000e6);
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

    function testBuyExactOutputCallsSwapExactOutputInGivenPool() external {
        vm.expectCall(
            address(aaplPool),
            abi.encodeWithSignature(
                "swapExactOutput(bool,uint256,address,bytes,bytes[])",
                true,
                1,
                address(this)
            )
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1,
            1000e6,
            block.timestamp + 1,
            PYTH_DATA
        );

        vm.expectCall(
            address(nvdaPool),
            abi.encodeWithSignature(
                "swapExactOutput(bool,uint256,address,bytes,bytes[])",
                true,
                5 ether,
                address(this)
            )
        );
        dclexRouter.buyExactOutput(
            address(nvdaStock),
            5 ether,
            1000e6,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactOutputCallsSwapExactOutputInGivenPool() external {
        vm.expectCall(
            address(aaplPool),
            abi.encodeWithSignature(
                "swapExactOutput(bool,uint256,address,bytes,bytes[])",
                false,
                1,
                address(this)
            )
        );
        dclexRouter.sellExactOutput(
            address(aaplStock),
            1,
            100 ether,
            block.timestamp + 1,
            PYTH_DATA
        );

        vm.expectCall(
            address(nvdaPool),
            abi.encodeWithSignature(
                "swapExactOutput(bool,uint256,address,bytes,bytes[])",
                false,
                500e6,
                address(this)
            )
        );
        dclexRouter.sellExactOutput(
            address(nvdaStock),
            500e6,
            100 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testBuyExactOutputCallerPaysForSwap() external {
        recordBalance(address(usdcToken), address(USER_1));
        vm.prank(USER_1);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            2 ether,
            40e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(40e6);

        recordBalance(address(usdcToken), address(USER_2));
        vm.prank(USER_2);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            2 ether,
            40e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(40e6);
    }

    function testSellExactOutputCallerPaysForSwap() external {
        recordBalance(address(aaplStock), address(USER_1));
        vm.prank(USER_1);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            40e6,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(2 ether);

        recordBalance(address(aaplStock), address(USER_2));
        vm.prank(USER_2);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            40e6,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(2 ether);
    }

    function testBuyExactOutputCallerReceivesSwapResult() external {
        recordBalance(address(aaplStock), address(USER_1));
        vm.prank(USER_1);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            2 ether,
            40e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(2 ether);

        recordBalance(address(aaplStock), address(USER_2));
        vm.prank(USER_2);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            2 ether,
            40e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(2 ether);
    }

    function testSellExactOutputCallerReceivesSwapResult() external {
        recordBalance(address(usdcToken), address(USER_1));
        vm.prank(USER_1);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            40e6,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(40e6);

        recordBalance(address(usdcToken), address(USER_2));
        vm.prank(USER_2);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            40e6,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(40e6);
    }

    function testBuyExactOutputDoesNotRevertWhenResultingInputAmountIsEqualOrLowerThanMaxInputAmount()
        external
    {
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            20e6 + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            20e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            2 ether,
            40e6 + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            2 ether,
            40e6,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactOutputDoesNotRevertWhenResultingInputAmountIsEqualOrLowerThanMaxInputAmount()
        external
    {
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            1 ether + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.sellExactOutput(
            address(aaplStock),
            40e6,
            2 ether + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.sellExactOutput(
            address(aaplStock),
            40e6,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testBuyExactOutputRevertsWhenResultingInputAmountIsAboveLimit()
        external
    {
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            20e6 - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            10e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            2 ether,
            40e6 - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            2 ether,
            10e6,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactOutputRevertsWhenResultingInputAmountIsAboveLimit()
        external
    {
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            1 ether - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            0.5 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            40e6,
            2 ether - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            40e6,
            0.5 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testBuyExactInputCallsSwapExactInputInGivenPool() external {
        vm.expectCall(
            address(aaplPool),
            abi.encodeWithSignature(
                "swapExactInput(bool,uint256,address,bytes,bytes[])",
                true,
                1,
                address(this)
            )
        );
        dclexRouter.buyExactInput(
            address(aaplStock),
            1,
            1000e6,
            block.timestamp + 1,
            PYTH_DATA
        );

        vm.expectCall(
            address(nvdaPool),
            abi.encodeWithSignature(
                "swapExactInput(bool,uint256,address,bytes,bytes[])",
                true,
                500e6,
                address(this)
            )
        );
        dclexRouter.buyExactInput(
            address(nvdaStock),
            500e6,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactInputCallsSwapExactInputInGivenPool() external {
        vm.expectCall(
            address(aaplPool),
            abi.encodeWithSignature(
                "swapExactInput(bool,uint256,address,bytes,bytes[])",
                false,
                1,
                address(this)
            )
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            1,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );

        vm.expectCall(
            address(nvdaPool),
            abi.encodeWithSignature(
                "swapExactInput(bool,uint256,address,bytes,bytes[])",
                false,
                5 ether,
                address(this)
            )
        );
        dclexRouter.sellExactInput(
            address(nvdaStock),
            5 ether,
            10e6,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testBuyExactInputCallerPaysForSwap() external {
        recordBalance(address(usdcToken), address(USER_1));
        vm.prank(USER_1);
        dclexRouter.buyExactInput(
            address(aaplStock),
            500e6,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(500e6);

        recordBalance(address(usdcToken), address(USER_2));
        vm.prank(USER_2);
        dclexRouter.buyExactInput(
            address(aaplStock),
            500e6,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(500e6);
    }

    function testSellExactInputCallerPaysForSwap() external {
        recordBalance(address(aaplStock), address(USER_1));
        vm.prank(USER_1);
        dclexRouter.sellExactInput(
            address(aaplStock),
            2 ether,
            10e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(2 ether);

        recordBalance(address(aaplStock), address(USER_2));
        vm.prank(USER_2);
        dclexRouter.sellExactInput(
            address(aaplStock),
            2 ether,
            10e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(2 ether);
    }

    function testBuyExactInputCallerReceivesSwapResult() external {
        recordBalance(address(aaplStock), address(USER_1));
        vm.prank(USER_1);
        dclexRouter.buyExactInput(
            address(aaplStock),
            40e6,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(2 ether);

        recordBalance(address(aaplStock), address(USER_2));
        vm.prank(USER_2);
        dclexRouter.buyExactInput(
            address(aaplStock),
            40e6,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(2 ether);
    }

    function testSellExactInputCallerReceivesSwapResult() external {
        recordBalance(address(usdcToken), address(USER_1));
        vm.prank(USER_1);
        dclexRouter.sellExactInput(
            address(aaplStock),
            2 ether,
            40e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(40e6);

        recordBalance(address(usdcToken), address(USER_2));
        vm.prank(USER_2);
        dclexRouter.sellExactInput(
            address(aaplStock),
            2 ether,
            40e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(40e6);
    }

    function testBuyExactInputDoesNotRevertWhenResultingOutputAmountIsEqualOrHigherThanMinOutputAmount()
        external
    {
        dclexRouter.buyExactInput(
            address(aaplStock),
            20e6,
            1 ether - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.buyExactInput(
            address(aaplStock),
            20e6,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.buyExactInput(
            address(aaplStock),
            40e6,
            1 ether - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.buyExactInput(
            address(aaplStock),
            40e6,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactInputDoesNotRevertWhenResultingOutputAmountIsEqualOrHigherThanMaxOutputAmount()
        external
    {
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            20e6 - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            20e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            2 ether,
            40e6 - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            2 ether,
            40e6,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testBuyExactInputRevertsWhenResultingOutputAmountIsBelowMinOutputAmount()
        external
    {
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.buyExactInput(
            address(aaplStock),
            20e6,
            1 ether + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.buyExactInput(
            address(aaplStock),
            10e6,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.buyExactInput(
            address(aaplStock),
            40e6,
            2 ether + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.buyExactInput(
            address(aaplStock),
            10e6,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactInputRevertsWhenResultingOutputAmountIsBelowMinOutputAmount()
        external
    {
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            20e6 + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            30e6,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.sellExactInput(
            address(aaplStock),
            2 ether,
            40e6 + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.sellExactInput(
            address(aaplStock),
            2 ether,
            50e6,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testBuyExactOutputRevertsIfDeadlineIsOlderThanCurrentBlockTimestamp()
        external
    {
        vm.warp(100);
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);

        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            20e6,
            10,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            20e6,
            99,
            PYTH_DATA
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            20e6,
            100,
            PYTH_DATA
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            20e6,
            101,
            PYTH_DATA
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            20e6,
            1000,
            PYTH_DATA
        );
    }

    function testSellExactOutputRevertsIfDeadlineIsOlderThanCurrentBlockTimestamp()
        external
    {
        vm.warp(100);
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);

        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            1 ether,
            10,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            1 ether,
            99,
            PYTH_DATA
        );
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            1 ether,
            100,
            PYTH_DATA
        );
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            1 ether,
            101,
            PYTH_DATA
        );
        dclexRouter.sellExactOutput(
            address(aaplStock),
            20e6,
            1 ether,
            1000,
            PYTH_DATA
        );
    }

    function testBuyExactInputRevertsIfDeadlineIsOlderThanCurrentBlockTimestamp()
        external
    {
        vm.warp(100);
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);

        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.buyExactInput(
            address(aaplStock),
            20e6,
            1 ether,
            10,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.buyExactInput(
            address(aaplStock),
            20e6,
            1 ether,
            99,
            PYTH_DATA
        );
        dclexRouter.buyExactInput(
            address(aaplStock),
            20e6,
            1 ether,
            100,
            PYTH_DATA
        );
        dclexRouter.buyExactInput(
            address(aaplStock),
            20e6,
            1 ether,
            101,
            PYTH_DATA
        );
        dclexRouter.buyExactInput(
            address(aaplStock),
            20e6,
            1 ether,
            1000,
            PYTH_DATA
        );
    }

    function testSellExactInputRevertsIfDeadlineIsOlderThanCurrentBlockTimestamp()
        external
    {
        vm.warp(100);
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);

        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            20e6,
            10,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            20e6,
            99,
            PYTH_DATA
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            20e6,
            100,
            PYTH_DATA
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            20e6,
            101,
            PYTH_DATA
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            20e6,
            1000,
            PYTH_DATA
        );
    }

    function testSwapExactInputRevertsIfDeadlineIsOlderThanCurrentBlockTimestamp()
        external
    {
        vm.warp(100);
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(NVDA_PRICE_FEED_ID, 30 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);

        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            10,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            99,
            PYTH_DATA
        );
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            100,
            PYTH_DATA
        );
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            101,
            PYTH_DATA
        );
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            1000,
            PYTH_DATA
        );
    }

    function testSwapExactInputTakesSpecifiedAmountOfInputTokens() external {
        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(3 ether);

        recordBalance(address(nvdaStock), address(this));
        dclexRouter.swapExactInput(
            address(nvdaStock),
            address(aaplStock),
            5 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(5 ether);

        uint256 ethBalanceBefore = address(this).balance;
        dclexRouter.swapExactInput{value: 1 ether}(
            address(0),
            address(aaplStock),
            0.001 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        uint256 ethBalanceAfter = address(this).balance;
        assertEq(ethBalanceBefore - ethBalanceAfter, 0.001 ether);

        recordBalance(address(nvdaStock), address(this));
        dclexRouter.swapExactInput(
            address(nvdaStock),
            address(0),
            10 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(10 ether);
    }

    function testSwapExactInputSendsBackSwapOutputTokens() external {
        recordBalance(address(nvdaStock), address(this));
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(2 ether);

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactInput(
            address(nvdaStock),
            address(aaplStock),
            5 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(7.5 ether);

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactInput{value: 0.001 ether}(
            address(0),
            address(aaplStock),
            0.001 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        // expect to receive about 0.15 AAPL minus 0.3% fee
        assertBalanceIncreasedApprox(0.14955 ether);

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactInput{value: 0.002 ether}(
            address(0),
            address(aaplStock),
            0.002 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        // expect to receive about 0.3 AAPL minus 0.3% fee
        assertBalanceIncreasedApprox(0.2991 ether);

        recordEthBalance(address(this));
        dclexRouter.swapExactInput(
            address(nvdaStock),
            address(0),
            10 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        // expect to receive about 0.1 ETH minus 0.3% fee
        assertEthBalanceIncreasedApprox(0.0997 ether);
    }

    function testSwapExactInputDoesNotChangeUsdcBalance() external {
        recordBalance(address(usdcToken), address(this));
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceNotChanged();

        recordBalance(address(usdcToken), address(this));
        dclexRouter.swapExactInput(
            address(nvdaStock),
            address(aaplStock),
            5 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceNotChanged();

        recordBalance(address(usdcToken), address(this));
        dclexRouter.swapExactInput{value: 0.001 ether}(
            address(0),
            address(aaplStock),
            0.001 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceNotChanged();

        recordBalance(address(usdcToken), address(this));
        dclexRouter.swapExactInput(
            address(nvdaStock),
            address(0),
            10 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceNotChanged();
    }

    function testSwapExactInputDoesNotRevertWhenResultingOutputAmountIsEqualOrHigherThanMinOutputAmount()
        external
    {
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            2 ether - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            6 ether,
            4 ether - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            6 ether,
            4 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSwapExactInputRevertsWhenResultingOutputAmountIsBelowMinOutputAmount()
        external
    {
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            2 ether + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            3 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            6 ether,
            4 ether + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__OutputTooLow.selector);
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            6 ether,
            5 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSwapExactInputUsesUniswapV4ToSwapEthToUsdc() external {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            true,
            -0.1 ether,
            TickMath.MIN_SQRT_PRICE + 1
        );
        vm.expectCall(
            address(manager),
            abi.encodeCall(manager.swap, (ethUsdcPoolKey, params, ""))
        );
        dclexRouter.swapExactInput{value: 0.1 ether}(
            address(0),
            address(aaplStock),
            0.1 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSwapExactInputUsesUniswapV4RouterToSwapUsdcToEth() external {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            false,
            -300e6,
            TickMath.MAX_SQRT_PRICE - 1
        );
        vm.expectCall(
            address(manager),
            abi.encodeCall(manager.swap, (ethUsdcPoolKey, params, ""))
        );
        dclexRouter.swapExactInput(
            address(nvdaStock),
            address(0),
            10 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSwapExactOutputRevertsIfDeadlineIsOlderThanCurrentBlockTimestamp()
        external
    {
        vm.warp(100);
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(NVDA_PRICE_FEED_ID, 30 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);

        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            type(uint256).max,
            10,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            type(uint256).max,
            99,
            PYTH_DATA
        );
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            type(uint256).max,
            100,
            PYTH_DATA
        );
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            type(uint256).max,
            101,
            PYTH_DATA
        );
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            type(uint256).max,
            1000,
            PYTH_DATA
        );
    }

    function testSwapExactOutputTakesInputTokens() external {
        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(4.5 ether);

        recordBalance(address(nvdaStock), address(this));
        dclexRouter.swapExactOutput(
            address(nvdaStock),
            address(aaplStock),
            6 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(4 ether);

        recordEthBalance(address(this));
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(0),
            address(aaplStock),
            1.5 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        // expect to pay about 0.01 plus 0.3% fee
        assertEthBalanceDecreasedApprox(0.01003 ether);

        recordEthBalance(address(this));
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(0),
            address(aaplStock),
            3 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        // expect to pay about 0.02 plus 0.3% fee
        assertEthBalanceDecreasedApprox(0.02006 ether);

        recordBalance(address(nvdaStock), address(this));
        dclexRouter.swapExactOutput(
            address(nvdaStock),
            address(0),
            0.1 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        // expect to pay about 0.1 ETH plus 0.3% fee
        assertBalanceDecreasedApprox(10.03 ether);
    }

    function testSwapExactOutputSendsBackSpecifiedAmountOfOutputTokens()
        external
    {
        recordBalance(address(nvdaStock), address(this));
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(3 ether);

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactOutput(
            address(nvdaStock),
            address(aaplStock),
            5 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(5 ether);

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactOutput{value: 0.1 ether}(
            address(0),
            address(aaplStock),
            2 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreasedApprox(2 ether);

        recordEthBalance(address(this));
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(aaplStock),
            address(0),
            0.1 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertEthBalanceIncreased(0.1 ether);
    }

    function testSwapExactOutputDoesNotChangeUsdcBalance() external {
        recordBalance(address(usdcToken), address(this));
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceNotChanged();

        recordBalance(address(usdcToken), address(this));
        dclexRouter.swapExactOutput(
            address(nvdaStock),
            address(aaplStock),
            5 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceNotChanged();

        recordBalance(address(usdcToken), address(this));
        dclexRouter.swapExactOutput{value: 0.1 ether}(
            address(0),
            address(aaplStock),
            2 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceNotChanged();

        recordBalance(address(usdcToken), address(this));
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(aaplStock),
            address(0),
            0.1 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceNotChanged();
    }

    function testSwapExactOutputDoesNotRevertWhenResultingInputAmountIsEqualOrLowerThanMaxInputAmount()
        external
    {
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            4.5 ether + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            4.5 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            6 ether,
            9 ether + 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            6 ether,
            9 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(0),
            address(nvdaStock),
            1 ether,
            0.0101 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        dclexRouter.swapExactOutput(
            address(nvdaStock),
            address(0),
            0.01 ether,
            1.01 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSwapExactOutputRevertsWhenResultingInputAmountIsAboveMaxInputAmount()
        external
    {
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            2 ether,
            3 ether - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            2 ether,
            2 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            4 ether,
            6 ether - 1,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            4 ether,
            5 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(0),
            address(nvdaStock),
            1 ether,
            0.01 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
        vm.expectRevert(DclexRouter.DclexRouter__InputTooHigh.selector);
        dclexRouter.swapExactOutput(
            address(nvdaStock),
            address(0),
            0.01 ether,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSwapExactOutputWorksEvenWhenCallerHasNoUsdc() external {
        // burn all USDC tokens
        usdcToken.transfer(address(1), usdcToken.balanceOf(address(this)));

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            3 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceDecreased(4.5 ether);

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(0),
            address(aaplStock),
            3 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
        assertBalanceIncreased(3 ether);
    }

    function testSwapExactOutputUsesUniswapV4ToSwapEthToUsdc() external {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            true,
            2e6,
            TickMath.MIN_SQRT_PRICE + 1
        );
        vm.expectCall(
            address(manager),
            abi.encodeCall(manager.swap, (ethUsdcPoolKey, params, ""))
        );
        dclexRouter.swapExactOutput{value: 0.1 ether}(
            address(0),
            address(aaplStock),
            0.1 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSwapExactOutputUsesUniswapV4RouterToSwapUsdcToEth() external {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            false,
            0.1 ether,
            TickMath.MAX_SQRT_PRICE - 1
        );
        vm.expectCall(
            address(manager),
            abi.encodeCall(manager.swap, (ethUsdcPoolKey, params, ""))
        );
        dclexRouter.swapExactOutput(
            address(nvdaStock),
            address(0),
            0.1 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSetPoolRevertsWhenCalledByNotAnOwner() external {
        vm.expectRevert("Ownable: caller is not the owner");
        dclexRouter.setPool(address(nvdaStock), nvdaPool);
    }

    function testSetPoolDoesNotRevertWhenCalledByOwner() external {
        vm.prank(ADMIN);
        dclexRouter.setPool(address(nvdaStock), nvdaPool);
    }

    function testBuyExactOutputRevertsWhenTokenUnknown() external {
        vm.expectRevert(DclexRouter.DclexRouter__UnknownToken.selector);
        dclexRouter.buyExactOutput(
            address(amznStock),
            1 ether,
            1000e6,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactOutputRevertsWhenTokenUnknown() external {
        vm.expectRevert(DclexRouter.DclexRouter__UnknownToken.selector);
        dclexRouter.sellExactOutput(
            address(amznStock),
            1e6,
            1 ether,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testBuyExactInputRevertsWhenTokenUnknown() external {
        vm.expectRevert(DclexRouter.DclexRouter__UnknownToken.selector);
        dclexRouter.buyExactInput(
            address(amznStock),
            1e6,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactInputRevertsWhenTokenUnknown() external {
        vm.expectRevert(DclexRouter.DclexRouter__UnknownToken.selector);
        dclexRouter.sellExactInput(
            address(amznStock),
            1 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSetPoolEmitsPoolSetForTokenEvent() external {
        vm.prank(ADMIN);
        vm.expectEmit(address(dclexRouter));
        emit PoolSetForToken(address(aaplStock), address(aaplPool));
        dclexRouter.setPool(address(aaplStock), aaplPool);
    }

    function testOnlyAddedDclexPoolsMayCallDclexSwapCallback() external {
        bytes memory data = abi.encode(
            DclexRouter.DclexSwapCallbackData(USER_1, false, address(0), 0)
        );

        vm.expectRevert(DclexRouter.DclexRouter__NotDclexPool.selector);
        dclexRouter.dclexSwapCallback(address(aaplStock), 1 ether, data);

        vm.expectRevert(DclexRouter.DclexRouter__NotDclexPool.selector);
        vm.prank(address(amznPool));
        dclexRouter.dclexSwapCallback(address(aaplStock), 1 ether, data);

        vm.prank(ADMIN);
        dclexRouter.setPool(address(amznStock), amznPool);
        vm.prank(address(amznPool));
        dclexRouter.dclexSwapCallback(address(aaplStock), 1 ether, data);

        vm.prank(ADMIN);
        // we remove pools by setting stock's pool to zero address
        dclexRouter.setPool(address(amznStock), DclexPool(address(0)));
        vm.expectRevert(DclexRouter.DclexRouter__NotDclexPool.selector);
        vm.prank(address(amznPool));
        dclexRouter.dclexSwapCallback(address(aaplStock), 1 ether, data);
    }

    function testBuyExactOutputUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(
            true,
            100e6,
            1 ether,
            80 ether,
            0.8 ether,
            address(this)
        );
        dclexRouter.buyExactOutput{value: expectedFee}(
            address(aaplStock),
            1 ether,
            type(uint256).max,
            block.timestamp + 1,
            pythData
        );
    }

    function testBuyExactInputUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(
            true,
            100e6,
            1 ether,
            80 ether,
            0.8 ether,
            address(this)
        );
        dclexRouter.buyExactInput{value: expectedFee}(
            address(aaplStock),
            100e6,
            0,
            block.timestamp + 1,
            pythData
        );
    }

    function testSellExactOutputUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(
            false,
            1 ether,
            100e6,
            80 ether,
            0.8 ether,
            address(this)
        );
        dclexRouter.sellExactOutput{value: expectedFee}(
            address(aaplStock),
            100e6,
            type(uint256).max,
            block.timestamp + 1,
            pythData
        );
    }

    function testSellExactInputUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(
            false,
            1 ether,
            100e6,
            80 ether,
            0.8 ether,
            address(this)
        );
        dclexRouter.sellExactInput{value: expectedFee}(
            address(aaplStock),
            1 ether,
            0,
            block.timestamp + 1,
            pythData
        );
    }

    function testSwapExactInputStockToStockUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](3);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(NVDA_PRICE_FEED_ID, 40 ether);
        pythData[2] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        vm.expectEmit();
        emit SwapExecuted(
            false,
            1 ether,
            100e6,
            80 ether,
            0.8 ether,
            address(this)
        );
        emit SwapExecuted(
            true,
            100e6,
            2 ether,
            40 ether,
            0.8 ether,
            address(this)
        );
        dclexRouter.swapExactInput{value: expectedFee}(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            block.timestamp + 1,
            pythData
        );
    }

    function testSwapExactInputStockToEthStockUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](3);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(NVDA_PRICE_FEED_ID, 40 ether);
        pythData[2] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        vm.expectEmit();
        emit SwapExecuted(
            false,
            0.3 ether,
            30e6,
            80 ether,
            0.8 ether,
            address(this)
        );
        dclexRouter.swapExactInput{value: expectedFee}(
            address(aaplStock),
            address(0),
            0.3 ether,
            0,
            block.timestamp + 1,
            pythData
        );
    }

    function testSwapExactInputEthToStockStockUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](3);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(NVDA_PRICE_FEED_ID, 40 ether);
        pythData[2] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactInput{value: 1 ether}(
            address(0),
            address(aaplStock),
            0.01 ether,
            0,
            block.timestamp + 1,
            pythData
        );
        // expect to receive 0.3 AAPL minus 0.3% fee
        assertBalanceIncreasedApprox(0.2991 ether);
    }

    function testSwapExactOutputStockToStockUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](3);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(NVDA_PRICE_FEED_ID, 40 ether);
        pythData[2] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        vm.expectEmit();
        emit SwapExecuted(
            false,
            1 ether,
            100e6,
            80 ether,
            0.8 ether,
            address(nvdaPool)
        );
        emit SwapExecuted(
            true,
            100e6,
            2 ether,
            40 ether,
            0.8 ether,
            address(this)
        );
        dclexRouter.swapExactOutput{value: expectedFee}(
            address(aaplStock),
            address(nvdaStock),
            2 ether,
            type(uint256).max,
            block.timestamp + 1,
            pythData
        );
    }

    function testSwapExactOutputStockToEthStockUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](3);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(NVDA_PRICE_FEED_ID, 40 ether);
        pythData[2] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        recordBalance(address(aaplStock), address(this));
        dclexRouter.swapExactOutput{value: expectedFee}(
            address(aaplStock),
            address(0),
            0.01 ether,
            type(uint256).max,
            block.timestamp + 1,
            pythData
        );
        assertBalanceDecreasedApprox(0.3009 ether);
    }

    function testSwapExactOutputEthToStockStockUpdatesPriceFeed() external {
        skip(1);
        bytes[] memory pythData = new bytes[](3);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 80 ether);
        pythData[1] = pythMock.getUpdatePriceData(NVDA_PRICE_FEED_ID, 40 ether);
        pythData[2] = pythMock.getUpdatePriceData(
            USDC_PRICE_FEED_ID,
            0.8 ether
        );

        vm.expectEmit();
        emit SwapExecuted(
            true,
            30e6,
            0.3 ether,
            80 ether,
            0.8 ether,
            address(this)
        );
        dclexRouter.swapExactOutput{value: 1 ether}(
            address(0),
            address(aaplStock),
            0.3 ether,
            type(uint256).max,
            block.timestamp + 1,
            pythData
        );
    }
}
