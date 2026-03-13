// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnifiedRouter} from "src/UnifiedRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {DigitalIdentity} from "dclex-mint/contracts/dclex/DigitalIdentity.sol";
import {Factory} from "dclex-mint/contracts/dclex/Factory.sol";
import {Stock} from "dclex-mint/contracts/dclex/Stock.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {HelperConfig as DclexProtocolHelperConfig} from "dclex-protocol/script/HelperConfig.s.sol";
import {DclexPythMock} from "dclex-protocol/test/PythMock.sol";
import {ITransferVerifier} from "dclex-mint/contracts/interfaces/ITransferVerifier.sol";

/// @title Mock dUSD Token
contract MockDUSD is ERC20 {
    constructor() ERC20("Digital USD", "dUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Mock WDEL Token
contract MockWDEL is ERC20 {
    constructor() ERC20("Wrapped DEL", "WDEL") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @title Mock V3 Factory
contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[tokenA][tokenB][fee];
    }

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[tokenA][tokenB][fee] = pool;
        pools[tokenB][tokenA][fee] = pool;
    }
}

/// @title UnifiedRouter Test
contract UnifiedRouterTest is Test {
    bytes[] internal PYTH_DATA = new bytes[](0);
    bytes32 internal AAPL_PRICE_FEED_ID;
    bytes32 internal NVDA_PRICE_FEED_ID;

    address private immutable ADMIN = makeAddr("admin");
    address private immutable MASTER_ADMIN = makeAddr("master_admin");
    address private immutable USER_1 = makeAddr("user_1");
    address private immutable USER_2 = makeAddr("user_2");

    MockDUSD internal dUSD;
    MockWDEL internal wdel;
    MockV3Factory internal v3Factory;
    UnifiedRouter internal router;

    DigitalIdentity internal digitalIdentity;
    Factory private stocksFactory;
    Stock internal aaplStock;
    Stock internal nvdaStock;
    DclexPool internal aaplPool;
    DclexPool internal nvdaPool;
    DclexPythMock private pythMock;
    DclexProtocolHelperConfig internal helperConfig;

    event DclexPoolSet(address indexed token, address indexed pool);
    event V3PoolSet(address indexed token, address indexed pool);

    receive() external payable {}

    function setUp() public {
        // Deploy mock tokens
        dUSD = new MockDUSD();
        wdel = new MockWDEL();
        v3Factory = new MockV3Factory();

        // Deploy UnifiedRouter
        router = new UnifiedRouter(
            address(dUSD),
            address(wdel),
            address(v3Factory)
        );

        // Deploy DCLEX infrastructure
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(
            ADMIN,
            MASTER_ADMIN
        );
        digitalIdentity = contracts.digitalIdentity;
        stocksFactory = contracts.stocksFactory;

        // Create stocks
        vm.startPrank(ADMIN);
        stocksFactory.createStocks("Apple", "AAPL");
        stocksFactory.createStocks("NVIDIA", "NVDA");
        vm.stopPrank();

        aaplStock = Stock(stocksFactory.stocks("AAPL"));
        nvdaStock = Stock(stocksFactory.stocks("NVDA"));

        // Deploy DclexPools
        helperConfig = new DclexProtocolHelperConfig();
        address pythAddress = helperConfig.getNetworkConfig().pyth;
        pythMock = new DclexPythMock(pythAddress);
        vm.deal(address(pythMock), 1 ether);

        AAPL_PRICE_FEED_ID = helperConfig.getPriceFeedId("AAPL");
        NVDA_PRICE_FEED_ID = helperConfig.getPriceFeedId("NVDA");

        // Deploy pools - using dUSD instead of USDC
        aaplPool = new DclexPool(
            aaplStock,
            IERC20(address(dUSD)),
            helperConfig.getNetworkConfig().pythAdapter,
            AAPL_PRICE_FEED_ID,
            ADMIN,
            60
        );

        nvdaPool = new DclexPool(
            nvdaStock,
            IERC20(address(dUSD)),
            helperConfig.getNetworkConfig().pythAdapter,
            NVDA_PRICE_FEED_ID,
            ADMIN,
            60
        );

        // Set up DIDs
        _setupDIDs();

        // Register pools with router
        router.setDclexPool(address(aaplStock), aaplPool);
        router.setDclexPool(address(nvdaStock), nvdaPool);

        // Set up pool fee curves
        vm.startPrank(ADMIN);
        aaplPool.setFeeCurve(0.001 ether, 0.0005 ether);
        nvdaPool.setFeeCurve(0.001 ether, 0.0005 ether);
        vm.stopPrank();

        // Mint tokens and provide liquidity
        _initializePools();
    }

    function _setupDIDs() internal {
        vm.startPrank(ADMIN);
        digitalIdentity.mintAdmin(USER_1, 0, bytes32(0), ITransferVerifier(address(0)));
        digitalIdentity.mintAdmin(USER_2, 0, bytes32(0), ITransferVerifier(address(0)));
        digitalIdentity.mintAdmin(address(router), 0, bytes32(0), ITransferVerifier(address(0)));
        digitalIdentity.mintAdmin(address(aaplPool), 0, bytes32(0), ITransferVerifier(address(0)));
        digitalIdentity.mintAdmin(address(nvdaPool), 0, bytes32(0), ITransferVerifier(address(0)));
        vm.stopPrank();
    }

    function _initializePools() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        // Give LP tokens
        vm.startPrank(ADMIN);
        digitalIdentity.mintAdmin(liquidityProvider, 0, bytes32(0), ITransferVerifier(address(0)));
        stocksFactory.forceMintStocks("AAPL", liquidityProvider, 10000 ether);
        stocksFactory.forceMintStocks("NVDA", liquidityProvider, 10000 ether);
        vm.stopPrank();

        dUSD.mint(liquidityProvider, 1000000e18);

        // Initialize pools
        vm.startPrank(liquidityProvider);
        aaplStock.approve(address(aaplPool), type(uint256).max);
        nvdaStock.approve(address(nvdaPool), type(uint256).max);
        dUSD.approve(address(aaplPool), type(uint256).max);
        dUSD.approve(address(nvdaPool), type(uint256).max);

        pythMock.setPrice(AAPL_PRICE_FEED_ID, 200e18);
        pythMock.setPrice(NVDA_PRICE_FEED_ID, 150e18);

        aaplPool.initialize(5000 ether, 500000e18, PYTH_DATA);
        nvdaPool.initialize(5000 ether, 500000e18, PYTH_DATA);
        vm.stopPrank();

        // Give users tokens
        _setupUserTokens(USER_1);
        _setupUserTokens(USER_2);
    }

    function _setupUserTokens(address user) internal {
        dUSD.mint(user, 100000e18);
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", user, 1000 ether);
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("NVDA", user, 1000 ether);
    }

    // ============ DclexPool Swap Tests ============

    function testBuyExactInput_DclexPool() public {
        uint256 inputAmount = 1000e18; // 1000 dUSD
        uint256 minOutput = 1 ether; // minimum 1 stock

        vm.startPrank(USER_1);
        dUSD.approve(address(router), inputAmount);

        uint256 aaplBefore = aaplStock.balanceOf(USER_1);
        uint256 dUsdBefore = dUSD.balanceOf(USER_1);

        router.buyExactInput(
            address(aaplStock),
            inputAmount,
            minOutput,
            block.timestamp + 1 hours,
            PYTH_DATA
        );

        uint256 aaplAfter = aaplStock.balanceOf(USER_1);
        uint256 dUsdAfter = dUSD.balanceOf(USER_1);

        vm.stopPrank();

        assertGt(aaplAfter, aaplBefore, "Should receive AAPL tokens");
        assertLt(dUsdAfter, dUsdBefore, "Should spend dUSD");
        assertEq(dUsdBefore - dUsdAfter, inputAmount, "Should spend exact input");
    }

    function testSellExactInput_DclexPool() public {
        uint256 inputAmount = 5 ether; // 5 AAPL
        uint256 minOutput = 100e18; // minimum 100 dUSD

        vm.startPrank(USER_1);
        aaplStock.approve(address(router), inputAmount);

        uint256 aaplBefore = aaplStock.balanceOf(USER_1);
        uint256 dUsdBefore = dUSD.balanceOf(USER_1);

        router.sellExactInput(
            address(aaplStock),
            inputAmount,
            minOutput,
            block.timestamp + 1 hours,
            PYTH_DATA
        );

        uint256 aaplAfter = aaplStock.balanceOf(USER_1);
        uint256 dUsdAfter = dUSD.balanceOf(USER_1);

        vm.stopPrank();

        assertLt(aaplAfter, aaplBefore, "Should sell AAPL tokens");
        assertGt(dUsdAfter, dUsdBefore, "Should receive dUSD");
        assertEq(aaplBefore - aaplAfter, inputAmount, "Should sell exact input");
    }

    function testBuyExactOutput_DclexPool() public {
        uint256 outputAmount = 5 ether; // 5 AAPL
        uint256 maxInput = 2000e18; // maximum 2000 dUSD

        vm.startPrank(USER_1);
        dUSD.approve(address(router), maxInput);

        uint256 aaplBefore = aaplStock.balanceOf(USER_1);

        router.buyExactOutput(
            address(aaplStock),
            outputAmount,
            maxInput,
            block.timestamp + 1 hours,
            PYTH_DATA
        );

        uint256 aaplAfter = aaplStock.balanceOf(USER_1);

        vm.stopPrank();

        assertEq(aaplAfter - aaplBefore, outputAmount, "Should receive exact output");
    }

    function testSellExactOutput_DclexPool() public {
        uint256 outputAmount = 500e18; // 500 dUSD
        uint256 maxInput = 10 ether; // maximum 10 AAPL

        vm.startPrank(USER_1);
        aaplStock.approve(address(router), maxInput);

        uint256 dUsdBefore = dUSD.balanceOf(USER_1);

        router.sellExactOutput(
            address(aaplStock),
            outputAmount,
            maxInput,
            block.timestamp + 1 hours,
            PYTH_DATA
        );

        uint256 dUsdAfter = dUSD.balanceOf(USER_1);

        vm.stopPrank();

        assertEq(dUsdAfter - dUsdBefore, outputAmount, "Should receive exact output");
    }

    // ============ Access Control Tests ============

    function testSetPool_onlyOwner() public {
        DclexPool newPool = new DclexPool(
            aaplStock,
            IERC20(address(dUSD)),
            helperConfig.getNetworkConfig().pythAdapter,
            AAPL_PRICE_FEED_ID,
            ADMIN,
            60
        );

        vm.prank(USER_1);
        vm.expectRevert();
        router.setDclexPool(address(aaplStock), newPool);
    }

    function testSetV3Pool_onlyOwner() public {
        vm.prank(USER_1);
        vm.expectRevert();
        router.setV3Pool(address(aaplStock), address(0x123));
    }

    // ============ View Function Tests ============

    function testGetPoolType() public view {
        assertEq(uint256(router.getPoolType(address(aaplStock))), uint256(UnifiedRouter.PoolType.Dclex));
        assertEq(uint256(router.getPoolType(address(nvdaStock))), uint256(UnifiedRouter.PoolType.Dclex));
        assertEq(uint256(router.getPoolType(address(0x123))), uint256(UnifiedRouter.PoolType.None));
    }

    function testAllStockTokens() public view {
        address[] memory tokens = router.allStockTokens();
        assertEq(tokens.length, 2);
    }

    // ============ Edge Case Tests ============

    function testRevert_unknownToken() public {
        address unknownToken = address(0x123);

        vm.startPrank(USER_1);
        vm.expectRevert(UnifiedRouter.UnifiedRouter__UnknownToken.selector);
        router.buyExactInput(
            unknownToken,
            1000e18,
            1 ether,
            block.timestamp + 1 hours,
            PYTH_DATA
        );
        vm.stopPrank();
    }

    function testRevert_deadlinePassed() public {
        vm.startPrank(USER_1);
        dUSD.approve(address(router), 1000e18);

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(UnifiedRouter.UnifiedRouter__DeadlinePassed.selector);
        router.buyExactInput(
            address(aaplStock),
            1000e18,
            1 ether,
            block.timestamp - 1 hours,
            PYTH_DATA
        );
        vm.stopPrank();
    }

    function testRevert_outputTooLow() public {
        vm.startPrank(USER_1);
        dUSD.approve(address(router), 100e18);

        // Request impossibly high minimum output
        vm.expectRevert(UnifiedRouter.UnifiedRouter__OutputTooLow.selector);
        router.buyExactInput(
            address(aaplStock),
            100e18, // Small input
            1000 ether, // Impossibly high minimum output
            block.timestamp + 1 hours,
            PYTH_DATA
        );
        vm.stopPrank();
    }

    // ============ Fuzz Tests ============

    function testFuzz_buyExactInput(uint256 inputAmount) public {
        inputAmount = bound(inputAmount, 100e18, 50000e18);

        vm.startPrank(USER_1);
        dUSD.approve(address(router), inputAmount);

        uint256 aaplBefore = aaplStock.balanceOf(USER_1);

        router.buyExactInput(
            address(aaplStock),
            inputAmount,
            0, // No minimum to avoid reverts
            block.timestamp + 1 hours,
            PYTH_DATA
        );

        uint256 aaplAfter = aaplStock.balanceOf(USER_1);

        vm.stopPrank();

        assertGt(aaplAfter, aaplBefore, "Should always receive some tokens");
    }

    function testFuzz_sellExactInput(uint256 inputAmount) public {
        inputAmount = bound(inputAmount, 1 ether, 100 ether);

        vm.startPrank(USER_1);
        aaplStock.approve(address(router), inputAmount);

        uint256 dUsdBefore = dUSD.balanceOf(USER_1);

        router.sellExactInput(
            address(aaplStock),
            inputAmount,
            0, // No minimum to avoid reverts
            block.timestamp + 1 hours,
            PYTH_DATA
        );

        uint256 dUsdAfter = dUSD.balanceOf(USER_1);

        vm.stopPrank();

        assertGt(dUsdAfter, dUsdBefore, "Should always receive some dUSD");
    }
}
