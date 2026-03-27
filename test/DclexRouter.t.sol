// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DclexPythMock} from "dclex-protocol/test/PythMock.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DeployDclexPool} from "dclex-protocol/script/DeployDclexPool.s.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";

import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {TestBalance} from "dclex-protocol/test/TestBalance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ISwapRouter
} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {
    UniswapV3Factory
} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {WDEL} from "../src/WDEL.sol";
import {PythAdapter} from "dclex-protocol/src/PythAdapter.sol";

contract DclexRouterTest is Test, TestBalance {
    bytes[] internal PYTH_DATA = new bytes[](0);
    bytes32 internal AAPL_PRICE_FEED_ID;
    bytes32 internal NVDA_PRICE_FEED_ID;
    bytes32 internal AMZN_PRICE_FEED_ID;
    bytes32 internal USDC_PRICE_FEED_ID;
    address private ADMIN = makeAddr("admin");
    address private immutable MASTER_ADMIN = makeAddr("master_admin");
    address private immutable POOL_ADMIN = makeAddr("pool_admin");
    address private immutable USER_1 = makeAddr("user_1");
    address private immutable USER_2 = makeAddr("user_2");
    address private immutable unapprovedUSDCAddress =
        makeAddr("unapproved_usdc");

    // V3 infrastructure
    UniswapV3Factory private v3Factory;
    SwapRouter private v3SwapRouter;
    Quoter private v3Quoter;
    WDEL private weth;
    address private ethUsdcPool;

    DigitalIdentity internal digitalIdentity;
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

    event PoolSetForToken(
        address indexed token,
        address pool,
        DclexRouter.PoolType poolType
    );
    event SwapExecuted(
        bool usdcInput,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 stockPrice,
        uint256 usdcPrice,
        address recipient
    );

    receive() external payable {}

    function setUp() public {
        // Deploy Dclex infrastructure
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(
            ADMIN,
            MASTER_ADMIN
        );
        digitalIdentity = contracts.digitalIdentity;
        stocksFactory = contracts.stocksFactory;
        vm.startPrank(ADMIN);
        string[] memory names = new string[](3);
        string[] memory symbols = new string[](3);
        names[0] = "Apple";
        names[1] = "NVIDIA";
        names[2] = "Amazon";
        symbols[0] = "AAPL";
        symbols[1] = "NVDA";
        symbols[2] = "AMZN";
        stocksFactory.createStocks(names, symbols);
        vm.stopPrank();
        aaplStock = Stock(contracts.stocksFactory.stocks("AAPL"));
        nvdaStock = Stock(contracts.stocksFactory.stocks("NVDA"));
        amznStock = Stock(contracts.stocksFactory.stocks("AMZN"));

        // Get USDC token
        DclexProtocolHelperConfig dclexProtocolHelperConfig = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig
            memory protocolConfig = dclexProtocolHelperConfig.getConfig();
        usdcToken = USDCMock(address(protocolConfig.usdcToken));

        // Deploy V3 infrastructure
        weth = new WDEL();
        v3Factory = new UniswapV3Factory();
        v3SwapRouter = new SwapRouter(address(v3Factory), address(weth));
        v3Quoter = new Quoter(address(v3Factory), address(weth));

        // Create and initialize ETH/USDC pool
        ethUsdcPool = v3Factory.createPool(
            address(weth),
            address(usdcToken),
            3000
        );
        // Initialize with ~3000 USDC per ETH price
        uint160 sqrtPriceX96 = 4339505179874779903; // approx 1 ETH = 3000 USDC
        IUniswapV3Pool(ethUsdcPool).initialize(sqrtPriceX96);

        // Deploy DclexRouter with V3
        dclexRouter = new DclexRouter(
            ISwapRouter(address(v3SwapRouter)),
            IQuoter(address(v3Quoter)),
            IERC20(address(usdcToken))
        );

        // Setup Pyth mock - need to get the underlying MockPyth from PythAdapter
        PythAdapter pythAdapter = PythAdapter(address(protocolConfig.oracle));
        pythMock = new DclexPythMock(address(pythAdapter.pyth()));
        vm.deal(address(pythMock), 1 ether);
        AAPL_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("AAPL");
        NVDA_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("NVDA");
        USDC_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("USDC");
        pythMock.updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        pythMock.updatePrice(NVDA_PRICE_FEED_ID, 30 ether);
        pythMock.updatePrice(USDC_PRICE_FEED_ID, 1 ether);

        // Deploy DclexPools
        DeployDclexPool dclexPoolDeployer = new DeployDclexPool();
        aaplPool = dclexPoolDeployer.run(
            IStock(address(aaplStock)),
            dclexProtocolHelperConfig,
            60
        );
        nvdaPool = dclexPoolDeployer.run(
            IStock(address(nvdaStock)),
            dclexProtocolHelperConfig,
            60
        );
        amznPool = dclexPoolDeployer.run(
            IStock(address(amznStock)),
            dclexProtocolHelperConfig,
            60
        );

        // Register pools
        dclexRouter.setPool(address(aaplStock), aaplPool);
        dclexRouter.setPool(address(nvdaStock), nvdaPool);
        dclexRouter.setPool(address(amznStock), DclexPool(address(0)));

        // Setup accounts
        setupAccount(address(this));
        setupAccount(USER_1);
        setupAccount(USER_2);
        vm.startPrank(ADMIN);
        digitalIdentity.mintAdmin(address(dclexRouter), 0, bytes32(0));
        digitalIdentity.mintAdmin(address(aaplPool), 2, bytes32(0));
        digitalIdentity.mintAdmin(address(nvdaPool), 2, bytes32(0));
        digitalIdentity.mintAdmin(address(amznPool), 2, bytes32(0));
        vm.stopPrank();

        // Initialize pools with liquidity
        vm.startPrank(address(this));
        aaplStock.approve(address(aaplPool), 100000 ether);
        nvdaStock.approve(address(nvdaPool), 100000 ether);
        usdcToken.approve(address(aaplPool), 100000e6);
        usdcToken.approve(address(nvdaPool), 100000e6);
        vm.stopPrank();
        aaplPool.initialize(100 ether, 2000e6, PYTH_DATA);
        nvdaPool.initialize(100 ether, 2000e6, PYTH_DATA);

        // Add liquidity to V3 ETH/USDC pool
        _addV3Liquidity();

        // Give test contract ETH for Pyth update fees
        vm.deal(address(this), 1 ether);

        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(unapprovedUSDCAddress, 0, bytes32(0));
        vm.prank(unapprovedUSDCAddress);
        aaplStock.approve(address(dclexRouter), 100000 ether);

        // Transfer ownership to admin
        dclexRouter.transferOwnership(ADMIN);
        ADMIN = dclexRouter.owner();
    }

    function _addV3Liquidity() private {
        // Add liquidity to V3 pool using direct mint callback
        // For testing, we'll use a simpler approach - deal tokens directly to pool
        uint256 wethAmount = 10 ether;
        uint256 usdcAmount = 30000e6;

        vm.deal(address(this), wethAmount);
        weth.deposit{value: wethAmount}();

        // Transfer tokens to pool for liquidity
        weth.transfer(ethUsdcPool, wethAmount);
        usdcToken.mint(ethUsdcPool, usdcAmount);

        // Mint initial liquidity position by calling mint on pool
        // Note: In production, this would use the position manager
        IUniswapV3Pool pool = IUniswapV3Pool(ethUsdcPool);
        int24 tickSpacing = pool.tickSpacing();
        int24 tickLower = (-887220 / tickSpacing) * tickSpacing;
        int24 tickUpper = (887220 / tickSpacing) * tickSpacing;

        // For testing purposes, we'll skip full V3 liquidity setup
        // and just ensure the pool has tokens for swaps
    }

    function setupAccount(address account) private {
        usdcToken.mint(account, 1000000e6);
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(account, 0, bytes32(0));
        vm.startPrank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", account, 100000 ether);
        stocksFactory.forceMintStocks("NVDA", account, 10000 ether);
        vm.stopPrank();
        vm.startPrank(account);
        aaplStock.approve(address(dclexRouter), 100000 ether);
        nvdaStock.approve(address(dclexRouter), 100000 ether);
        usdcToken.approve(address(dclexRouter), 100000 ether);
        vm.stopPrank();
    }

    // ============ Basic Buy/Sell Tests (Custom Pools) ============

    function testBuyExactOutputCallsSwapExactOutputInGivenPool() external {
        vm.expectCall(
            address(aaplPool),
            abi.encodeWithSignature(
                "swapExactOutput(bool,uint256,address,bytes,bytes[])",
                true,
                1 ether,
                address(this)
            )
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
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
                1 ether,
                address(this)
            )
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
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

    // ============ Deadline Tests ============

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

    // ============ Cross-Pool Swap Tests (Stock to Stock) ============

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

    // ============ Pool Registry Tests ============

    function testSetPoolRevertsWhenCalledByNotAnOwner() external {
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
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

    function testAllStockTokensReturnsAllCurrentlyRegisteredStockTokens()
        external
    {
        address[] memory result = dclexRouter.allStockTokens();
        assertEq(result.length, 2);
        assertEq(result[0], address(aaplStock));
        assertEq(result[1], address(nvdaStock));

        vm.prank(ADMIN);
        dclexRouter.setPool(address(aaplStock), DclexPool(address(0)));
        result = dclexRouter.allStockTokens();
        assertEq(result.length, 1);
        assertEq(result[0], address(nvdaStock));
    }

    // ============ Pool Type Registry Tests ============

    function testSetCustomPoolAddsPoolWithCorrectType() external {
        vm.prank(ADMIN);
        dclexRouter.setCustomPool(address(amznStock), amznPool);

        assertEq(
            uint256(dclexRouter.getPoolType(address(amznStock))),
            uint256(DclexRouter.PoolType.CUSTOM)
        );
        assertEq(
            address(dclexRouter.stockToCustomPool(address(amznStock))),
            address(amznPool)
        );
    }

    function testSetAMMPoolAddsPoolWithCorrectType() external {
        address mockAMMPool = makeAddr("mockAMMPool");

        vm.prank(ADMIN);
        dclexRouter.setAMMPool(address(amznStock), mockAMMPool, 3000);

        assertEq(
            uint256(dclexRouter.getPoolType(address(amznStock))),
            uint256(DclexRouter.PoolType.AMM)
        );
        assertEq(dclexRouter.stockToAMMPool(address(amznStock)), mockAMMPool);
    }

    function testSetAMMPoolCanBeRemoved() external {
        address mockAMMPool = makeAddr("mockAMMPool");

        vm.prank(ADMIN);
        dclexRouter.setAMMPool(address(amznStock), mockAMMPool, 3000);

        vm.prank(ADMIN);
        dclexRouter.setAMMPool(address(amznStock), address(0), 0);

        assertEq(
            uint256(dclexRouter.getPoolType(address(amznStock))),
            uint256(DclexRouter.PoolType.NONE)
        );
    }

    // ============ Price Feed Tests ============

    function testBuyExactOutputUpdatesPriceFeed() external {
        // Test with setup prices: AAPL=$20, USDC=$1
        // Output: 1 share, Input needed: 1*20 = 20 USDC
        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(
            true,
            20e6,
            1 ether,
            20 ether,
            1 ether,
            address(this)
        );
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testBuyExactInputUpdatesPriceFeed() external {
        // Test with setup prices: AAPL=$20, USDC=$1
        // Input: 100 USDC, Output: 100/20 = 5 shares
        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(
            true,
            100e6,
            5 ether,
            20 ether,
            1 ether,
            address(this)
        );
        dclexRouter.buyExactInput(
            address(aaplStock),
            100e6,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactOutputUpdatesPriceFeed() external {
        // Test with setup prices: AAPL=$20, USDC=$1
        // Output: 100 USDC, Input needed: 100/20 = 5 shares
        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(
            false,
            5 ether,
            100e6,
            20 ether,
            1 ether,
            address(this)
        );
        dclexRouter.sellExactOutput(
            address(aaplStock),
            100e6,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSellExactInputUpdatesPriceFeed() external {
        // Test with setup prices: AAPL=$20, USDC=$1
        // Input: 1 share, Output: 1*20 = 20 USDC
        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(
            false,
            1 ether,
            20e6,
            20 ether,
            1 ether,
            address(this)
        );
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testSwapExactInputStockToStockUpdatesPriceFeed() external {
        // Test with setup prices: AAPL=$20, NVDA=$30, USDC=$1
        // Input: 1 AAPL = $20 -> 20 USDC -> 20/30 NVDA = 0.666... NVDA
        vm.expectEmit();
        emit SwapExecuted(
            false, // selling AAPL
            1 ether, // 1 share input
            20e6, // 20 USDC output
            20 ether, // AAPL price
            1 ether, // USDC price
            address(dclexRouter)
        );
        emit SwapExecuted(
            true, // buying NVDA
            20e6, // 20 USDC input
            666666666666666666, // ~0.666 NVDA output
            30 ether, // NVDA price
            1 ether, // USDC price
            address(this)
        );
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    // ============ Stock-to-Stock Without USDC Approval Tests ============

    function testStockToStockExactInputSwapDoesNotRequireApprovingUSDC()
        external
    {
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", unapprovedUSDCAddress, 1 ether);

        vm.prank(unapprovedUSDCAddress);
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            block.timestamp + 1,
            PYTH_DATA
        );
    }

    function testStockToStockExactOutputSwapDoesNotRequireApprovingUSDC()
        external
    {
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", unapprovedUSDCAddress, 1.5 ether);

        vm.prank(unapprovedUSDCAddress);
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            type(uint256).max,
            block.timestamp + 1,
            PYTH_DATA
        );
    }
}
