// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    MessageHashUtils
} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FIOracle} from "dclex-protocol/src/FIOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {BatchPoolInitializer} from "src/BatchPoolInitializer.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";

interface IDclexRouter {
    function stockTokenToPool(address token) external view returns (address);
    function stockToCustomPool(address token) external view returns (address);
}

/// @notice Mints stock + dUSD, then initializes all 44 pools on chain 2028.
///         Uses FIOracle signed price data (price = 100 USD for all stocks).
///         The deployer must be the FIOracle trusted signer (set by DeployMissingPools).
///         stockAmount: 10 shares (18 decimals) = 10e18
///         dusdAmount:  1000 dUSD (6 decimals) = 1000e6
///         Pool value ~= 10 * 100 + 1000 = 2000 USD each side
contract InitializeAllPools is Script {
    string internal constant DUSD_SYMBOL = "dUSD";
    uint256 internal constant INITIAL_UPDATE_FEE = 0.001 ether;

    // Mock prices: all stocks @ $100
    // For $100: price = 10000000000 (1e10), expo = -8 → 1e10 * 1e-8 = 100
    int64 constant MOCK_PRICE = 10_000_000_000; // $100 with expo -8
    int32 constant EXPO = -8;

    // 10 shares per pool (18 decimals)
    uint256 constant STOCK_AMOUNT = 10e18;
    // 1000 dUSD per pool (6 decimals) - roughly $1000 to match $100 * 10 shares
    uint256 constant DUSD_AMOUNT = 1_000e6;

    // Local Anvil constants
    uint256 constant LOCAL_STOCK_AMOUNT = 1000e18; // 1000 stock tokens (18 decimals)
    uint256 constant LOCAL_USDC_AMOUNT = 10_000e6; // 10,000 USDC (6 decimals)
    int64 constant LOCAL_MOCK_PRICE = 1_000_000_000; // $10 with expo -8
    int32 constant LOCAL_EXPO = -8;

    struct StockInfo {
        string symbol;
        bytes32 priceFeedId;
    }

    function getAllStocks() internal pure returns (StockInfo[] memory stocks) {
        stocks = new StockInfo[](44);
        stocks[0] = StockInfo(
            "AMZN",
            0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a
        );
        stocks[1] = StockInfo(
            "V",
            0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90
        );
        stocks[2] = StockInfo(
            "JPM",
            0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e
        );
        stocks[3] = StockInfo(
            "GE",
            0xe1d3115c6e7ac649faca875b3102f1000ab5e06b03f6903e0d699f0f5315ba86
        );
        stocks[4] = StockInfo(
            "AI",
            0xafb12c5ccf50495c7a7b04447410d7feb4b3218a663ecbd96aa82e676d3c4f1e
        );
        stocks[5] = StockInfo(
            "CPNG",
            0x5557d206aa0dd037fc082f03bbd78653f01465d280ea930bc93251f0eb60c707
        );
        stocks[6] = StockInfo(
            "DOW",
            0xf3b50961ff387a3d68217e2715637d0add6013e7ecb83c36ae8062f97c46929e
        );
        stocks[7] = StockInfo(
            "CAT",
            0xad04597ba688c350a97265fcb60585d6a80ebd37e147b817c94f101a32e58b4c
        );
        stocks[8] = StockInfo(
            "MRK",
            0xc81114e16ec3cbcdf20197ac974aed5a254b941773971260ce09e7caebd6af46
        );
        stocks[9] = StockInfo(
            "AMGN",
            0x10946973bfcc936b423d52ee2c5a538d96427626fe6d1a7dae14b1c401d1e794
        );
        stocks[10] = StockInfo(
            "KO",
            0x9aa471dccea36b90703325225ac76189baf7e0cc286b8843de1de4f31f9caa7d
        );
        stocks[11] = StockInfo(
            "MSTR",
            0xe1e80251e5f5184f2195008382538e847fafc36f751896889dd3d1b1f6111f09
        );
        stocks[12] = StockInfo(
            "GS",
            0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554
        );
        stocks[13] = StockInfo(
            "DIS",
            0x703e36203020ae6761e6298975764e266fb869210db9b35dd4e4225fa68217d0
        );
        stocks[14] = StockInfo(
            "WMT",
            0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc
        );
        stocks[15] = StockInfo(
            "NVDA",
            0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593
        );
        stocks[16] = StockInfo(
            "IBM",
            0xcfd44471407f4da89d469242546bb56f5c626d5bef9bd8b9327783065b43c3ef
        );
        stocks[17] = StockInfo(
            "MCD",
            0xd3178156b7c0f6ce10d6da7d347952a672467b51708baaf1a57ffe1fb005824a
        );
        stocks[18] = StockInfo(
            "BA",
            0x8419416ba640c8bbbcf2d464561ed7dd860db1e38e51cec9baf1e34c4be839ae
        );
        stocks[19] = StockInfo(
            "AXP",
            0x9ff7b9a93df40f6d7edc8184173c50f4ae72152c6142f001e8202a26f951d710
        );
        stocks[20] = StockInfo(
            "TRV",
            0xd45392f678a1287b8412ed2aaa326def204a5c234df7cb5552d756c332283d81
        );
        stocks[21] = StockInfo(
            "CVX",
            0xf464e36fd4ef2f1c3dc30801a9ab470dcdaaa0af14dd3cf6ae17a7fca9e051c5
        );
        stocks[22] = StockInfo(
            "JNJ",
            0x12848738d5db3aef52f51d78d98fc8b8b8450ffb19fb3aeeb67d38f8c147ff63
        );
        stocks[23] = StockInfo(
            "AMC",
            0x5b1703d7eb9dc8662a61556a2ca2f9861747c3fc803e01ba5a8ce35cb50a13a1
        );
        stocks[24] = StockInfo(
            "CSCO",
            0x3f4b77dd904e849f70e1e812b7811de57202b49bc47c56391275c0f45f2ec481
        );
        stocks[25] = StockInfo(
            "HON",
            0x107918baaaafb79cd9df1c8369e44ac21136d95f3ca33f2373b78f24ba1e3e6a
        );
        stocks[26] = StockInfo(
            "BLK",
            0x68d038affb5895f357d7b3527a6d3cd6a54edd0fe754a1248fb3462e47828b08
        );
        stocks[27] = StockInfo(
            "NKE",
            0x67649450b4ca4bfff97cbaf96d2fd9e40f6db148cb65999140154415e4378e14
        );
        stocks[28] = StockInfo(
            "INTC",
            0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff
        );
        stocks[29] = StockInfo(
            "MMM",
            0xfd05a384ba19863cbdfc6575bed584f041ef50554bab3ab482eabe4ea58d9f81
        );
        stocks[30] = StockInfo(
            "VZ",
            0x6672325a220c0ee1166add709d5ba2e51c185888360c01edc76293257ef68b58
        );
        stocks[31] = StockInfo(
            "NFLX",
            0x8376cfd7ca8bcdf372ced05307b24dced1f15b1afafdeff715664598f15a3dd2
        );
        stocks[32] = StockInfo(
            "WBA",
            0xed5c2a2711e2a638573add9a8aded37028aea4ac69f1431a1ced9d9db61b2225
        );
        stocks[33] = StockInfo(
            "UNH",
            0x05380f8817eb1316c0b35ac19c3caa92c9aa9ea6be1555986c46dce97fed6afd
        );
        stocks[34] = StockInfo(
            "TSLA",
            0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1
        );
        stocks[35] = StockInfo(
            "COIN",
            0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245
        );
        stocks[36] = StockInfo(
            "AAPL",
            0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688
        );
        stocks[37] = StockInfo(
            "GOOG",
            0xe65ff435be42630439c96396653a342829e877e2aafaeaf1a10d0ee5fd2cf3f2
        );
        stocks[38] = StockInfo(
            "MSFT",
            0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1
        );
        stocks[39] = StockInfo(
            "META",
            0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe
        );
        stocks[40] = StockInfo(
            "CRM",
            0xfeff234600320f4d6bb5a01d02570a9725c1e424977f2b823f7231e6857bdae8
        );
        stocks[41] = StockInfo(
            "GME",
            0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6
        );
        stocks[42] = StockInfo(
            "PG",
            0xad2fda41998f4e7be99a2a7b27273bd16f183d9adfc014a4f5e5d3d6cd519bf4
        );
        stocks[43] = StockInfo(
            "HD",
            0xb3a83dbe70b62241b0f916212e097465a1b31085fa30da3342dd35468ca17ca5
        );
    }

    /// @notice Creates FIOracle-compatible signed price data (117 bytes).
    ///         The deployer must be the FIOracle trusted signer.
    function signedPriceData(
        uint256 signerKey,
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(feedId, price, expo, publishTime)
        );
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(
            messageHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedHash);
        return abi.encodePacked(feedId, price, expo, publishTime, v, r, s);
    }

    struct InitCtx {
        Factory factory;
        IDclexRouter router;
        FIOracle fiOracle;
        IERC20 dusdToken;
        address backendSigner;
        uint256 adminKey;
        uint256 masterAdminKey;
    }

    /// @notice Initialize all canonical DclexPools on a target chain.
    ///         Required env: ADMIN_PRIVATE_KEY, MASTER_ADMIN_PRIVATE_KEY,
    ///         DCLEX_ROUTER, DCLEX_FACTORY, DCLEX_FIORACLE,
    ///         DCLEX_BACKEND_SIGNER.
    ///         Optional env: DCLEX_DUSD_SYMBOL ("dUSD"),
    ///         DCLEX_BATCH_INIT (skip setup if set; runs init only — used
    ///         for the second-pass run when publishTime drift matters).
    ///
    /// Two-pass usage on slow chains (publishTime ages between
    /// `vm.unixTime()` and when the actual tx mines):
    ///   1. Run without DCLEX_BATCH_INIT — deploys batchInit, grants
    ///      roles, funds it with dUSD, exits before init. Logs the
    ///      batchInit address.
    ///   2. Re-run with DCLEX_BATCH_INIT=<addr> — does sign + initializeAll
    ///      in a single tx so publishTime is at most ~10s old at mining.
    ///      Cleans up roles after.
    function run() external {
        InitCtx memory ctx = _loadCtx();

        (address[] memory pendingPools, string[] memory pendingSymbols, bytes32[] memory pendingFeeds, uint256 pendingCount)
            = _collectPending(ctx.factory, ctx.router, getAllStocks());

        if (pendingCount == 0) {
            console.log("Nothing to initialize.");
            return;
        }
        console.log("Pools to initialize:", pendingCount);

        address existing = vm.envOr("DCLEX_BATCH_INIT", address(0));
        if (existing == address(0)) {
            FIOraclePoolBatchInitializer batchInit = _setupBatchInit(ctx, pendingCount);
            console.log("Setup done. Re-run with DCLEX_BATCH_INIT=", address(batchInit));
            return;
        }
        FIOraclePoolBatchInitializer batchInit = FIOraclePoolBatchInitializer(payable(existing));
        _runBatchInit(ctx, batchInit, pendingPools, pendingSymbols, pendingFeeds, pendingCount);
        // Teardown is a separate script run (cleanup_init_roles or
        // manual cast send) so this run has only ONE broadcast — keeps
        // publishTime ~10s old at mining (under the 60s staleness window).
        console.log("Initialized", pendingCount, "pools. Run cleanup separately.");
    }

    function _loadCtx() internal view returns (InitCtx memory ctx) {
        ctx.factory = Factory(vm.envAddress("DCLEX_FACTORY"));
        ctx.router = IDclexRouter(vm.envAddress("DCLEX_ROUTER"));
        ctx.fiOracle = FIOracle(vm.envAddress("DCLEX_FIORACLE"));
        ctx.backendSigner = vm.envAddress("DCLEX_BACKEND_SIGNER");
        ctx.adminKey = vm.envUint("ADMIN_PRIVATE_KEY");
        ctx.masterAdminKey = vm.envUint("MASTER_ADMIN_PRIVATE_KEY");
        ctx.dusdToken = IERC20(ctx.factory.stablecoins(DUSD_SYMBOL));
        require(address(ctx.dusdToken) != address(0), "dUSD not registered on Factory");
    }

    function _setupBatchInit(InitCtx memory ctx, uint256 pendingCount)
        internal
        returns (FIOraclePoolBatchInitializer batchInit)
    {
        // Admin temporarily takes the trustedSigner role so the script
        // can sign mock price data with adminKey.
        vm.startBroadcast(ctx.adminKey);
        ctx.fiOracle.setTrustedSigner(vm.addr(ctx.adminKey));
        batchInit = new FIOraclePoolBatchInitializer();
        DigitalIdentity(address(ctx.factory.getDID())).mintAdmin(address(batchInit), 2, bytes32(0));
        ctx.factory.forceMintStablecoin(DUSD_SYMBOL, address(batchInit), DUSD_AMOUNT * pendingCount);
        vm.stopBroadcast();

        // Granting DEFAULT_ADMIN_ROLE on Factory requires MASTER_ADMIN_ROLE.
        vm.startBroadcast(ctx.masterAdminKey);
        ctx.factory.grantRole(0x00, address(batchInit));
        vm.stopBroadcast();
    }

    function _runBatchInit(
        InitCtx memory ctx,
        FIOraclePoolBatchInitializer batchInit,
        address[] memory pendingPools,
        string[] memory pendingSymbols,
        bytes32[] memory pendingFeeds,
        uint256 pendingCount
    ) internal {
        // Forge forks the chain at some past block, so sim block.timestamp
        // lags wall clock by ~30-60s. Sync sim to wall clock so the
        // FuturePublishTime check (publishTime <= block.timestamp) passes
        // in sim AND publishTime is recent enough that the real chain
        // (block.timestamp ≈ wall clock at mining) won't trip StalePrice.
        uint64 publishTime = uint64(vm.unixTime() / 1000);
        vm.warp(publishTime);
        vm.startBroadcast(ctx.adminKey);
        bytes[] memory priceUpdateData = new bytes[](pendingCount);
        for (uint256 i = 0; i < pendingCount; i++) {
            priceUpdateData[i] = signedPriceData(
                ctx.adminKey, pendingFeeds[i], MOCK_PRICE, EXPO, publishTime
            );
        }
        batchInit.initializeAll{value: INITIAL_UPDATE_FEE * pendingCount}(
            FIOraclePoolBatchInitializer.InitParams({
                factory: ctx.factory,
                dusdToken: ctx.dusdToken,
                pools: pendingPools,
                stockSymbols: pendingSymbols,
                priceUpdateData: priceUpdateData,
                stockAmount: STOCK_AMOUNT,
                dusdAmount: DUSD_AMOUNT,
                feePerPool: INITIAL_UPDATE_FEE
            })
        );
        vm.stopBroadcast();
    }

    function _teardown(InitCtx memory ctx, FIOraclePoolBatchInitializer batchInit) internal {
        vm.startBroadcast(ctx.masterAdminKey);
        ctx.factory.revokeRole(0x00, address(batchInit));
        vm.stopBroadcast();

        vm.startBroadcast(ctx.adminKey);
        ctx.fiOracle.setTrustedSigner(ctx.backendSigner);
        vm.stopBroadcast();
    }

    function _collectPending(
        Factory factory,
        IDclexRouter router,
        StockInfo[] memory allStocks
    ) internal view returns (
        address[] memory pools,
        string[] memory symbols,
        bytes32[] memory feeds,
        uint256 count
    ) {
        address[] memory tmpPools = new address[](allStocks.length);
        string[] memory tmpSymbols = new string[](allStocks.length);
        bytes32[] memory tmpFeeds = new bytes32[](allStocks.length);
        for (uint256 i = 0; i < allStocks.length; i++) {
            address stockAddr = factory.stocks(allStocks[i].symbol);
            if (stockAddr == address(0)) continue;
            address poolAddr = router.stockToCustomPool(stockAddr);
            if (poolAddr == address(0)) continue;
            // Already initialized? skip.
            if (IERC20(stockAddr).balanceOf(poolAddr) > 0) continue;
            tmpPools[count] = poolAddr;
            tmpSymbols[count] = allStocks[i].symbol;
            tmpFeeds[count] = allStocks[i].priceFeedId;
            count++;
        }
        pools = new address[](count);
        symbols = new string[](count);
        feeds = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            pools[i] = tmpPools[i];
            symbols[i] = tmpSymbols[i];
            feeds[i] = tmpFeeds[i];
        }
    }

    /// @notice Initializes all pools on local Anvil (chainId 31337).
    ///         Uses MockPyth for price data and dynamically reads stocks from Factory.
    ///         Optimized to use BatchPoolInitializer for single-transaction deployment.
    function runLocal(
        address factoryAddress,
        address routerAddress,
        address mockPythAddress
    ) external {
        Factory factory = Factory(factoryAddress);
        uint256 stocksCount = factory.getStocksCount();
        console.log("Initializing liquidity for", stocksCount, "pools");

        if (stocksCount == 0) {
            console.log("No stocks found, skipping liquidity initialization");
            return;
        }

        // Collect symbols and price feed IDs using helper
        (string[] memory symbols, bytes32[] memory priceFeedIds) = _collectStockData(factory, stocksCount);

        // Calculate ETH needed for Pyth fees
        uint256 totalFee = _calculateTotalFee(mockPythAddress, stocksCount);

        console.log("Deploying BatchPoolInitializer for", stocksCount, "pools");

        // Execute batch initialization
        _executeBatchInit(factory, routerAddress, mockPythAddress, symbols, priceFeedIds, totalFee);

        console.log("Pool liquidity initialization complete!");
    }

    function _collectStockData(Factory factory, uint256 stocksCount)
        private
        returns (string[] memory symbols, bytes32[] memory priceFeedIds)
    {
        DclexProtocolHelperConfig helperConfig = new DclexProtocolHelperConfig();
        symbols = new string[](stocksCount);
        priceFeedIds = new bytes32[](stocksCount);

        for (uint256 i = 0; i < stocksCount; i++) {
            symbols[i] = factory.symbols(i);
            priceFeedIds[i] = helperConfig.getPriceFeedId(symbols[i]);
        }
    }

    function _calculateTotalFee(address mockPythAddress, uint256 stocksCount) private view returns (uint256) {
        MockPyth mockPyth = MockPyth(mockPythAddress);
        bytes[] memory sampleData = new bytes[](1);
        sampleData[0] = mockPyth.createPriceFeedUpdateData(
            bytes32(0), LOCAL_MOCK_PRICE, 10, LOCAL_EXPO,
            LOCAL_MOCK_PRICE, 10, uint64(block.timestamp), uint64(block.timestamp)
        );
        return mockPyth.getUpdateFee(sampleData) * stocksCount;
    }

    function _executeBatchInit(
        Factory factory,
        address routerAddress,
        address mockPythAddress,
        string[] memory symbols,
        bytes32[] memory priceFeedIds,
        uint256 totalFee
    ) private {
        DigitalIdentity digitalIdentity = DigitalIdentity(address(factory.getDID()));
        bytes32 adminRole = digitalIdentity.DEFAULT_ADMIN_ROLE();

        vm.startBroadcast();

        BatchPoolInitializer batchInit = new BatchPoolInitializer();

        // Grant temporary admin roles
        digitalIdentity.grantRole(adminRole, address(batchInit));
        factory.grantRole(adminRole, address(batchInit));

        // Initialize all pools
        batchInit.initializeAllPools{value: totalFee}(
            factory,
            routerAddress,
            mockPythAddress,
            symbols,
            priceFeedIds
        );

        // Revoke admin roles
        digitalIdentity.revokeRole(adminRole, address(batchInit));
        factory.revokeRole(adminRole, address(batchInit));

        vm.stopBroadcast();
    }
}
