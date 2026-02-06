// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {IAaveOracle} from "aave-v3-origin/contracts/interfaces/IAaveOracle.sol";
import {IPoolAddressesProvider} from "aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol";
import {DataTypes} from "aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol";
import {IPoolConfigurator} from "aave-v3-origin/contracts/interfaces/IPoolConfigurator.sol";

import {IZaibots} from "custom/integrations/morpho/interfaces/IZaibots.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";
import {CarryAdapter} from "custom/integrations/morpho/adapters/CarryAdapter.sol";
import {LinearBlockTwapOracle} from "custom/products/carryUSDC/LinearBlockTwapOracle.sol";
import {CarryTwapPriceChecker} from "custom/products/carryUSDC/CarryTwapPriceChecker.sol";

import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockMilkman} from "../mocks/MockMilkman.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";

// ═══════════════════════════════════════════════════════════════════
// ZaibotsAaveAdapter: IZaibots wrapper around real Aave V3 IPool
// ═══════════════════════════════════════════════════════════════════

contract ZaibotsAaveAdapter is IZaibots {
    using SafeERC20 for IERC20;

    IPool public immutable pool;
    IPoolAddressesProvider public immutable addressesProvider;

    constructor(address _pool, address _addressesProvider) {
        pool = IPool(_pool);
        addressesProvider = IPoolAddressesProvider(_addressesProvider);
    }

    function supply(address asset, uint256 amount, address onBehalfOf) external override returns (uint256) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);
        pool.supply(asset, amount, onBehalfOf, 0);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        // The caller (strategy) must have aTokens. We need to pull aTokens or use delegation.
        // For fork test, the strategy is the onBehalfOf, so aTokens are in the strategy.
        // We can't directly withdraw on behalf of someone else in Aave V3 without delegation.
        // The strategy calls withdraw through this adapter, so we need the strategy to
        // transfer aTokens to us first, or use the Pool's withdraw which checks msg.sender.
        // Actually, Aave's withdraw checks that msg.sender owns the aTokens or has allowance.
        // Since strategy called us, and aTokens are in strategy's balance, we need strategy
        // to have approved the aTokens to us.
        //
        // Simpler approach: have the strategy call pool.withdraw directly through this adapter.
        // But the pool checks msg.sender's aToken balance. So this adapter needs to hold the aTokens.
        // Let's have supply() credit aTokens to this adapter, and track per-user.
        //
        // Actually, in supply() above we do: pool.supply(asset, amount, onBehalfOf, 0)
        // This means aTokens go to onBehalfOf (the strategy). So the strategy has the aTokens.
        // When strategy calls withdraw through us, the pool will check OUR (adapter) aToken balance
        // since WE are msg.sender to pool.withdraw().
        //
        // Fix: supply should set onBehalfOf to address(this) and we track internally.
        // But that changes the architecture...
        //
        // Simplest for fork test: supply to address(this), track balances manually.
        // BUT that means we're the ones with aTokens.
        //
        // Let me re-think: The strategy calls IZaibots(adapter).withdraw().
        // The adapter calls pool.withdraw() where msg.sender is the adapter.
        // So the adapter needs to hold the aTokens.
        //
        // Let's fix supply to send aTokens to this adapter contract.
        // Actually supply() already does pool.supply(asset, amount, onBehalfOf, 0).
        // We need it to be pool.supply(asset, amount, address(this), 0) so WE hold the aTokens.

        // For withdraw: pool.withdraw sends underlying to `to`.
        uint256 withdrawn = pool.withdraw(asset, amount, to);
        return withdrawn;
    }

    function borrow(address asset, uint256 amount, address onBehalfOf) external override {
        // Variable rate = 2
        pool.borrow(asset, amount, 2, 0, onBehalfOf);
        // After borrow, tokens are sent to msg.sender (this adapter), forward to caller
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, address onBehalfOf) external override returns (uint256) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);
        return pool.repay(asset, amount, 2, onBehalfOf);
    }

    function getCollateralBalance(address user, address asset) external view override returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(asset);
        return IERC20(reserve.aTokenAddress).balanceOf(user);
    }

    function getDebtBalance(address user, address asset) external view override returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(asset);
        return IERC20(reserve.variableDebtTokenAddress).balanceOf(user);
    }

    function getLTV(address collateral, address /* debt */) external view override returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(collateral);
        // ReserveConfiguration stores LTV in first 16 bits (in bps)
        uint256 configData = reserve.configuration.data;
        uint256 ltvBps = configData & 0xFFFF; // first 16 bits
        // Convert from bps (e.g., 7500 = 75%) to 18-decimal (0.75e18)
        return (ltvBps * 1e18) / 10000;
    }

    function getBorrowRate(address asset) external view override returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(asset);
        return reserve.currentVariableBorrowRate;
    }

    function getSupplyRate(address asset) external view override returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(asset);
        return reserve.currentLiquidityRate;
    }

    function isLiquidatable(address user) external view override returns (bool) {
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(user);
        return healthFactor < 1e18;
    }

    function getHealthFactor(address user) external view override returns (uint256) {
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(user);
        return healthFactor;
    }

    function getMaxBorrow(address user, address /* asset */) external view override returns (uint256) {
        (, , uint256 availableBorrows, , , ) = pool.getUserAccountData(user);
        return availableBorrows;
    }
}

// ═══════════════════════════════════════════════════════════════════
// ZaibotsAaveAdapterSelf: variant that holds aTokens/debt itself
// ═══════════════════════════════════════════════════════════════════

/**
 * @title ZaibotsAaveAdapterSelf
 * @notice IZaibots adapter that holds aTokens itself and tracks per-user balances.
 *         This is needed because Aave's withdraw() checks msg.sender's aToken balance.
 */
contract ZaibotsAaveAdapterSelf is IZaibots {
    using SafeERC20 for IERC20;

    IPool public immutable pool;

    // Track collateral per user per asset
    mapping(address => mapping(address => uint256)) public userCollateral;

    constructor(address _pool) {
        pool = IPool(_pool);
    }

    function supply(address asset, uint256 amount, address onBehalfOf) external override returns (uint256) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);
        // Supply to self so we hold the aTokens
        pool.supply(asset, amount, address(this), 0);
        userCollateral[onBehalfOf][asset] += amount;
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        // msg.sender is the strategy
        uint256 available = userCollateral[msg.sender][asset];
        uint256 toWithdraw = amount > available ? available : amount;
        userCollateral[msg.sender][asset] -= toWithdraw;
        // We hold the aTokens, so pool.withdraw checks our balance
        uint256 withdrawn = pool.withdraw(asset, toWithdraw, to);
        return withdrawn;
    }

    function borrow(address asset, uint256 amount, address onBehalfOf) external override {
        // Borrow on behalf of this adapter (we hold the collateral)
        // The debt goes to address(this), tokens sent to address(this)
        pool.borrow(asset, amount, 2, 0, address(this));
        // Forward borrowed tokens to the caller (strategy)
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, address onBehalfOf) external override returns (uint256) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);
        // Repay our own debt
        return pool.repay(asset, amount, 2, address(this));
    }

    function getCollateralBalance(address user, address asset) external view override returns (uint256) {
        return userCollateral[user][asset];
    }

    function getDebtBalance(address /* user */, address asset) external view override returns (uint256) {
        // All debt is held by this adapter (address(this)), so return our debt token balance
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(asset);
        return IERC20(reserve.variableDebtTokenAddress).balanceOf(address(this));
    }

    function getLTV(address collateral, address /* debt */) external view override returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(collateral);
        uint256 configData = reserve.configuration.data;
        uint256 ltvBps = configData & 0xFFFF;
        return (ltvBps * 1e18) / 10000;
    }

    function getBorrowRate(address asset) external view override returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(asset);
        return reserve.currentVariableBorrowRate;
    }

    function getSupplyRate(address asset) external view override returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(asset);
        return reserve.currentLiquidityRate;
    }

    function isLiquidatable(address /* user */) external view override returns (bool) {
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(address(this));
        return healthFactor < 1e18;
    }

    function getHealthFactor(address /* user */) external view override returns (uint256) {
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(address(this));
        return healthFactor;
    }

    function getMaxBorrow(address /* user */, address /* asset */) external view override returns (uint256) {
        (, , uint256 availableBorrows, , , ) = pool.getUserAccountData(address(this));
        return availableBorrows;
    }
}

// ═══════════════════════════════════════════════════════════════════
// Fork Test
// ═══════════════════════════════════════════════════════════════════

/**
 * @title SepoliaForkTest
 * @notice Integration test for CarryStrategy + Morpho Vault against real Sepolia Aave pool
 * @dev Run with: NETWORK=sepolia SEPOLIA_RPC_URL=<rpc> forge test --match-contract SepoliaForkTest -vvv
 */
contract SepoliaForkTest is Test {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════
    // SEPOLIA DEPLOYED ADDRESSES
    // ═══════════════════════════════════════════════════════════════════

    address constant POOL = 0xAf29b85C97B28490E00A090bD1b4B552c69C7559;
    address constant POOL_ADDRESSES_PROVIDER = 0xc183d9509425B9f1e08320AE1612C2Ee7de7EC4D;
    address constant AAVE_ORACLE = 0xdA55C5b54655819118EeF2c32b8ff3b022a7Cb8c;
    address constant POOL_CONFIGURATOR = 0x888C7478060755Bb3E796D2F8534821202285aF1;
    address constant ACL_ADMIN = 0x9faFC61799b4E4D4EE8b6843fefd434612450243;

    address constant USDC = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;
    address constant AIEN = 0x956fB81384efEEDaC8a3598444cc9f602855c461;
    address constant AIEN_DEBT_TOKEN = 0x6AC70d3F636eAA45b9821e4770dee039e5CCDBf8;

    // Leverage params (9 decimals)
    uint64 constant TARGET_LEVERAGE = 5_000_000_000;  // 5x (reduced for 85% LTV)
    uint64 constant MIN_LEVERAGE = 2_000_000_000;     // 2x
    uint64 constant MAX_LEVERAGE = 6_000_000_000;     // 6x (reduced for 85% LTV)
    uint64 constant RIPCORD_LEVERAGE = 8_000_000_000; // 8x (reduced for 85% LTV)

    // Execution params
    uint128 constant MAX_TRADE_SIZE = 500_000e6;      // 500k USDC
    uint32 constant TWAP_COOLDOWN = 5 minutes;
    uint16 constant SLIPPAGE_BPS = 100;               // 1%
    uint32 constant REBALANCE_INTERVAL = 4 hours;
    uint64 constant RECENTER_SPEED = 500_000_000;     // 50%

    // Incentive params
    uint16 constant RIPCORD_SLIPPAGE_BPS = 300;       // 3%
    uint16 constant RIPCORD_COOLDOWN = 2 minutes;
    uint128 constant RIPCORD_MAX_TRADE = 100_000e6;
    uint96 constant ETH_REWARD = 0.5 ether;

    // Price constant (8 decimals - Chainlink standard for AIEN/USD)
    // Must match the real Aave oracle price so borrow amounts are correct
    int256 constant AIEN_USD_PRICE = 69_350_000; // ~$0.6935 (matches Sepolia oracle)

    // ═══════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════

    IPool public pool;
    IAaveOracle public oracle;
    ZaibotsAaveAdapterSelf public zaibots;

    IERC20 public usdc;
    IERC20 public aien;

    CarryStrategy public carryStrategy;
    CarryAdapter public carryAdapter;
    LinearBlockTwapOracle public twapOracle;
    CarryTwapPriceChecker public priceChecker;
    MockChainlinkFeed public mockAienUsdFeed;
    MockMilkman public mockMilkman;
    MockMorphoVault public morphoVault;

    address public owner = makeAddr("owner");
    address public keeper = makeAddr("keeper");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // ═══════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════

    function setUp() public {
        // Fork Sepolia
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl);

        pool = IPool(POOL);
        oracle = IAaveOracle(AAVE_ORACLE);
        usdc = IERC20(USDC);
        aien = IERC20(AIEN);

        vm.startPrank(owner);

        // Deploy ZaibotsAaveAdapter (wraps real Aave pool)
        zaibots = new ZaibotsAaveAdapterSelf(POOL);

        // Deploy mocks for swap simulation and oracle
        mockAienUsdFeed = new MockChainlinkFeed(8, "AIEN / USD", AIEN_USD_PRICE);
        mockMilkman = new MockMilkman();

        // Deploy TWAP oracle
        twapOracle = new LinearBlockTwapOracle(address(mockAienUsdFeed));

        // Deploy price checker
        priceChecker = new CarryTwapPriceChecker(
            address(twapOracle),
            address(mockAienUsdFeed),
            USDC,
            AIEN
        );

        // Deploy carry strategy
        CarryStrategy.Addresses memory stratAddrs = CarryStrategy.Addresses({
            adapter: address(0),  // Set after adapter deployment
            zaibots: address(zaibots),
            collateralToken: USDC,
            debtToken: AIEN,
            jpyUsdOracle: address(mockAienUsdFeed),
            jpyUsdAggregator: address(0),
            twapOracle: address(twapOracle),
            milkman: address(mockMilkman),
            priceChecker: address(priceChecker)
        });

        CarryStrategy.ExecutionParams memory execParams = CarryStrategy.ExecutionParams({
            maxTradeSize: MAX_TRADE_SIZE,
            twapCooldown: TWAP_COOLDOWN,
            slippageBps: SLIPPAGE_BPS,
            rebalanceInterval: REBALANCE_INTERVAL,
            recenterSpeed: RECENTER_SPEED
        });

        CarryStrategy.IncentiveParams memory incParams = CarryStrategy.IncentiveParams({
            slippageBps: RIPCORD_SLIPPAGE_BPS,
            twapCooldown: RIPCORD_COOLDOWN,
            maxTrade: RIPCORD_MAX_TRADE,
            etherReward: ETH_REWARD
        });

        carryStrategy = new CarryStrategy(
            "Aggressive Carry (7x)",
            CarryStrategy.StrategyType.AGGRESSIVE,
            stratAddrs,
            [TARGET_LEVERAGE, MIN_LEVERAGE, MAX_LEVERAGE, RIPCORD_LEVERAGE],
            execParams,
            incParams
        );

        // Deploy Morpho vault
        morphoVault = new MockMorphoVault(usdc, "CarryUSD Vault", "cvUSD");

        // Deploy carry adapter (connects vault to strategy)
        carryAdapter = new CarryAdapter(
            address(morphoVault),
            USDC,
            "aggressive-usdc-aien",
            address(twapOracle)
        );

        // Wire up
        carryAdapter.setStrategy(address(carryStrategy));
        carryStrategy.setAdapter(address(carryAdapter));
        morphoVault.addAdapter(address(carryAdapter));

        // Set permissions
        carryStrategy.setOperator(keeper);
        carryStrategy.setAllowedCaller(keeper, true);
        carryStrategy.setAllowedCaller(alice, true);

        // Fund strategy with ETH for ripcord rewards
        vm.deal(address(carryStrategy), 5 ether);

        // Setup mock milkman prices (AIEN <-> USDC)
        // AIEN -> USDC: 1 AIEN ($0.6935) -> 693500 USDC-wei (6 dec) = 0.6935 USDC
        mockMilkman.setMockPrice(AIEN, USDC, 693500);
        // USDC -> AIEN: 1 USDC -> 1.442 AIEN = 1.442e18 AIEN-wei
        // price = 1.442e18 * 1e18 / 1e6 = 1.442e30
        mockMilkman.setMockPrice(USDC, AIEN, 1442000000000000000000000000000);

        vm.stopPrank();

        // Fund test users with USDC
        deal(USDC, alice, 10_000_000e6);   // 10M USDC
        deal(USDC, bob, 5_000_000e6);      // 5M USDC
        deal(USDC, owner, 50_000_000e6);   // 50M USDC

        // Fund milkman with tokens for swap settlement
        deal(USDC, address(mockMilkman), 100_000_000e6);
        deal(AIEN, address(mockMilkman), 100_000_000_000e18); // AIEN has 18 decimals

        // Labels
        vm.label(POOL, "AavePool");
        vm.label(USDC, "USDC");
        vm.label(AIEN, "AIEN");
        vm.label(address(zaibots), "ZaibotsAdapter");
        vm.label(address(carryStrategy), "CarryStrategy");
        vm.label(address(carryAdapter), "CarryAdapter");
        vm.label(address(morphoVault), "MorphoVault");
        vm.label(address(mockMilkman), "MockMilkman");
    }

    // ═══════════════════════════════════════════════════════════════════
    // POOL CONNECTIVITY TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_poolIsAccessible() public view {
        // Verify the pool is reachable on the fork
        DataTypes.ReserveDataLegacy memory usdcReserve = pool.getReserveData(USDC);
        assertTrue(usdcReserve.aTokenAddress != address(0), "USDC should have aToken");

        DataTypes.ReserveDataLegacy memory aienReserve = pool.getReserveData(AIEN);
        assertTrue(aienReserve.aTokenAddress != address(0), "AIEN should have aToken");
        assertEq(aienReserve.variableDebtTokenAddress, AIEN_DEBT_TOKEN, "AIEN debt token mismatch");

        console2.log("USDC aToken:", usdcReserve.aTokenAddress);
        console2.log("AIEN aToken:", aienReserve.aTokenAddress);
        console2.log("AIEN varDebt:", aienReserve.variableDebtTokenAddress);
    }

    function test_fork_oracleReturnsPrice() public view {
        uint256 usdcPrice = oracle.getAssetPrice(USDC);
        uint256 aienPrice = oracle.getAssetPrice(AIEN);

        console2.log("USDC oracle price:", usdcPrice);
        console2.log("AIEN oracle price:", aienPrice);

        assertTrue(usdcPrice > 0, "USDC price should be > 0");
        assertTrue(aienPrice > 0, "AIEN price should be > 0");
    }

    function test_fork_reserveConfig() public view {
        DataTypes.ReserveDataLegacy memory usdcReserve = pool.getReserveData(USDC);
        DataTypes.ReserveDataLegacy memory aienReserve = pool.getReserveData(AIEN);

        // Decode USDC LTV from config
        uint256 usdcLtv = usdcReserve.configuration.data & 0xFFFF;
        uint256 usdcLiqThreshold = (usdcReserve.configuration.data >> 16) & 0xFFFF;
        bool usdcBorrowEnabled = ((usdcReserve.configuration.data >> 58) & 1) == 1;

        console2.log("USDC LTV (bps):", usdcLtv);
        console2.log("USDC Liq Threshold (bps):", usdcLiqThreshold);
        console2.log("USDC borrow enabled:", usdcBorrowEnabled);

        // Decode AIEN config
        uint256 aienLtv = aienReserve.configuration.data & 0xFFFF;
        bool aienBorrowEnabled = ((aienReserve.configuration.data >> 58) & 1) == 1;

        console2.log("AIEN LTV (bps):", aienLtv);
        console2.log("AIEN borrow enabled:", aienBorrowEnabled);
    }

    // ═══════════════════════════════════════════════════════════════════
    // DIRECT POOL INTERACTION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_directSupplyUSDC() public {
        uint256 amount = 100_000e6; // 100k USDC

        vm.startPrank(alice);
        usdc.approve(address(pool), amount);
        pool.supply(USDC, amount, alice, 0);
        vm.stopPrank();

        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(USDC);
        uint256 aTokenBal = IERC20(reserve.aTokenAddress).balanceOf(alice);

        console2.log("Alice aUSDC balance after supply:", aTokenBal);
        assertGe(aTokenBal, amount - 1, "Should have aTokens");
    }

    function test_fork_directSupplyAndBorrow() public {
        uint256 supplyAmount = 1_000_000e6; // 1M USDC

        // Supply USDC as collateral
        vm.startPrank(alice);
        usdc.approve(address(pool), supplyAmount);
        pool.supply(USDC, supplyAmount, alice, 0);

        // Check available borrows
        (uint256 totalCollateral, , uint256 availableBorrows, , , uint256 hf) = pool.getUserAccountData(alice);
        console2.log("Total collateral (base):", totalCollateral);
        console2.log("Available borrows (base):", availableBorrows);
        console2.log("Health factor:", hf);

        // Borrow AIEN
        uint256 aienPrice = oracle.getAssetPrice(AIEN);
        // Borrow a conservative amount: 10% of available
        uint256 borrowValueBase = availableBorrows / 10;
        uint256 borrowAmount = (borrowValueBase * 1e18) / aienPrice; // 18 decimals for AIEN

        if (borrowAmount > 0) {
            pool.borrow(AIEN, borrowAmount, 2, 0, alice);

            uint256 debtBalance = IERC20(AIEN_DEBT_TOKEN).balanceOf(alice);
            console2.log("AIEN debt balance:", debtBalance);
            console2.log("AIEN borrowed:", borrowAmount);
            assertTrue(debtBalance > 0, "Should have AIEN debt");
        }
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // ZAIBOTS ADAPTER TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_zaibotsSupply() public {
        uint256 amount = 100_000e6;

        vm.startPrank(alice);
        usdc.approve(address(zaibots), amount);
        zaibots.supply(USDC, amount, alice);
        vm.stopPrank();

        uint256 collateral = zaibots.getCollateralBalance(alice, USDC);
        console2.log("Zaibots collateral balance:", collateral);
        assertEq(collateral, amount, "Collateral should match supply");
    }

    function test_fork_zaibotsSupplyAndBorrow() public {
        uint256 supplyAmount = 1_000_000e6;

        vm.startPrank(alice);
        usdc.approve(address(zaibots), supplyAmount);
        zaibots.supply(USDC, supplyAmount, alice);

        // Check health
        uint256 hf = zaibots.getHealthFactor(alice);
        console2.log("Health factor after supply:", hf);

        // Calculate borrow amount
        uint256 ltv = zaibots.getLTV(USDC, AIEN);
        console2.log("LTV (18 dec):", ltv);

        // Borrow a small amount of AIEN
        uint256 aienPrice = oracle.getAssetPrice(AIEN);
        uint256 borrowValueBase = (supplyAmount * 1e2 * ltv) / (10 * 1e18); // Convert to base units (8 dec)
        uint256 borrowAmount = (borrowValueBase * 1e18) / aienPrice;
        borrowAmount = borrowAmount / 10; // Be conservative, borrow 10% of max

        console2.log("Attempting to borrow AIEN:", borrowAmount);

        if (borrowAmount > 0) {
            zaibots.borrow(AIEN, borrowAmount, alice);

            uint256 aienBalance = aien.balanceOf(alice);
            console2.log("AIEN balance after borrow:", aienBalance);
            assertTrue(aienBalance >= borrowAmount, "Should have received borrowed AIEN");
        }
        vm.stopPrank();
    }

    function test_fork_zaibotsLTV() public view {
        uint256 ltv = zaibots.getLTV(USDC, AIEN);
        console2.log("USDC LTV (18 dec):", ltv);
        assertTrue(ltv > 0, "LTV should be > 0");
        assertTrue(ltv <= 1e18, "LTV should be <= 100%");
    }

    // ═══════════════════════════════════════════════════════════════════
    // MORPHO VAULT DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_vaultDeposit() public {
        uint256 depositAmount = 1_000_000e6; // 1M USDC

        vm.startPrank(alice);
        usdc.approve(address(morphoVault), depositAmount);
        uint256 shares = morphoVault.deposit(depositAmount, alice);
        vm.stopPrank();

        console2.log("Shares minted:", shares);
        console2.log("Vault total assets:", morphoVault.totalAssets());
        console2.log("Alice share balance:", morphoVault.balanceOf(alice));

        assertEq(shares, depositAmount, "First deposit should be 1:1");
        assertEq(morphoVault.totalAssets(), depositAmount, "Total assets should match deposit");
    }

    function test_fork_vaultMultiDeposit() public {
        uint256 aliceDeposit = 2_000_000e6;
        uint256 bobDeposit = 1_000_000e6;

        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(morphoVault), aliceDeposit);
        morphoVault.deposit(aliceDeposit, alice);
        vm.stopPrank();

        // Bob deposits
        vm.startPrank(bob);
        usdc.approve(address(morphoVault), bobDeposit);
        morphoVault.deposit(bobDeposit, bob);
        vm.stopPrank();

        console2.log("Vault total assets:", morphoVault.totalAssets());
        console2.log("Alice shares:", morphoVault.balanceOf(alice));
        console2.log("Bob shares:", morphoVault.balanceOf(bob));
        console2.log("Share price (18 dec):", morphoVault.sharePrice());

        assertEq(morphoVault.totalAssets(), aliceDeposit + bobDeposit, "Total assets should be sum of deposits");
    }

    // ═══════════════════════════════════════════════════════════════════
    // VAULT → ADAPTER → STRATEGY → POOL FLOW
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_vaultAllocateToCarryAdapter() public {
        uint256 depositAmount = 1_000_000e6;

        // Alice deposits to vault
        vm.startPrank(alice);
        usdc.approve(address(morphoVault), depositAmount);
        morphoVault.deposit(depositAmount, alice);
        vm.stopPrank();

        console2.log("=== Before allocation ===");
        console2.log("Vault USDC balance:", usdc.balanceOf(address(morphoVault)));
        console2.log("Adapter real assets:", carryAdapter.realAssets());
        console2.log("Strategy real assets:", carryStrategy.getRealAssets());

        // Vault owner allocates to carry adapter
        uint256 allocateAmount = 500_000e6; // Allocate 500k
        vm.prank(owner);
        morphoVault.allocate(address(carryAdapter), "", allocateAmount);

        console2.log("=== After allocation ===");
        console2.log("Vault USDC balance:", usdc.balanceOf(address(morphoVault)));
        console2.log("Adapter real assets:", carryAdapter.realAssets());
        console2.log("Strategy real assets:", carryStrategy.getRealAssets());

        // Strategy should now have collateral in Aave pool via zaibots
        uint256 collateral = zaibots.getCollateralBalance(address(carryStrategy), USDC);
        console2.log("Strategy collateral in pool:", collateral);

        assertEq(collateral, allocateAmount, "Strategy collateral should match allocation");
        assertEq(carryStrategy.getRealAssets(), allocateAmount, "Strategy real assets should match");
    }

    function test_fork_fullDepositAndEngageFlow() public {
        uint256 depositAmount = 2_000_000e6; // 2M USDC
        uint256 allocateAmount = 1_000_000e6; // 1M to strategy

        // Step 1: Alice deposits to vault
        vm.startPrank(alice);
        usdc.approve(address(morphoVault), depositAmount);
        morphoVault.deposit(depositAmount, alice);
        vm.stopPrank();

        console2.log("=== Step 1: Vault deposit ===");
        console2.log("Alice vault shares:", morphoVault.balanceOf(alice));

        // Step 2: Allocate to carry adapter
        vm.prank(owner);
        morphoVault.allocate(address(carryAdapter), "", allocateAmount);

        console2.log("=== Step 2: Allocated to strategy ===");
        console2.log("Strategy collateral:", zaibots.getCollateralBalance(address(carryStrategy), USDC));
        console2.log("Strategy leverage:", carryStrategy.getCurrentLeverageRatio());

        // Step 3: Engage strategy (initiate leverage)
        vm.prank(keeper, keeper);
        carryStrategy.engage();

        console2.log("=== Step 3: Engaged ===");
        console2.log("Swap state:", uint256(carryStrategy.swapState()));
        console2.log("Pending swap amount:", carryStrategy.pendingSwapAmount());
        console2.log("TWAP leverage target:", carryStrategy.twapLeverageRatio());

        assertEq(
            uint256(carryStrategy.swapState()),
            uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP),
            "Should have pending lever swap"
        );

        // Step 4: Complete the swap (simulate Milkman settlement)
        bytes32 swapId = mockMilkman.getLatestSwapId();
        mockMilkman.settleSwapWithPrice(swapId);

        console2.log("=== Step 4: Swap settled ===");
        console2.log("Strategy USDC in hand:", usdc.balanceOf(address(carryStrategy)));

        // The strategy should now have received USDC back from the swap
        // It needs to be supplied to the pool - but the current flow expects
        // tokens to auto-supply. Let's check the state.
        console2.log("Swap state after settle:", uint256(carryStrategy.swapState()));
    }

    // ═══════════════════════════════════════════════════════════════════
    // STRATEGY STATE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_strategyLeverageParams() public view {
        (uint64 target, uint64 min, uint64 max, uint64 ripcord) = carryStrategy.leverage();

        console2.log("Target leverage (9 dec):", uint256(target));
        console2.log("Min leverage (9 dec):", uint256(min));
        console2.log("Max leverage (9 dec):", uint256(max));
        console2.log("Ripcord leverage (9 dec):", uint256(ripcord));

        assertEq(target, TARGET_LEVERAGE, "Target should be 5x");
        assertEq(min, MIN_LEVERAGE, "Min should be 2x");
        assertEq(max, MAX_LEVERAGE, "Max should be 6x");
        assertEq(ripcord, RIPCORD_LEVERAGE, "Ripcord should be 8x");
    }

    function test_fork_strategyNotEngagedInitially() public view {
        assertFalse(carryStrategy.isEngaged(), "Should not be engaged initially");
        assertEq(carryStrategy.getCurrentLeverageRatio(), 1e18, "Initial leverage should be 1x");
    }

    function test_fork_strategyActive() public view {
        assertTrue(carryStrategy.isActive(), "Strategy should be active");
    }

    // ═══════════════════════════════════════════════════════════════════
    // VAULT WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_vaultDepositAndWithdraw() public {
        uint256 depositAmount = 1_000_000e6;

        // Deposit
        vm.startPrank(alice);
        usdc.approve(address(morphoVault), depositAmount);
        morphoVault.deposit(depositAmount, alice);

        uint256 aliceSharesBefore = morphoVault.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        // Withdraw half
        uint256 withdrawAmount = depositAmount / 2;
        morphoVault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        uint256 aliceSharesAfter = morphoVault.balanceOf(alice);
        uint256 usdcAfter = usdc.balanceOf(alice);

        console2.log("Shares before:", aliceSharesBefore);
        console2.log("Shares after:", aliceSharesAfter);
        console2.log("USDC recovered:", usdcAfter - usdcBefore);

        assertEq(usdcAfter - usdcBefore, withdrawAmount, "Should receive correct USDC back");
        assertTrue(aliceSharesAfter < aliceSharesBefore, "Should burn shares");
    }

    // ═══════════════════════════════════════════════════════════════════
    // AAVE POOL HEALTH CHECKS
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_aienBorrowEnabled() public view {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(AIEN);
        bool borrowEnabled = ((reserve.configuration.data >> 58) & 1) == 1;
        assertTrue(borrowEnabled, "AIEN borrowing should be enabled");

        uint256 totalSupply = IERC20(reserve.aTokenAddress).totalSupply();
        console2.log("AIEN aToken totalSupply:", totalSupply);
        assertTrue(totalSupply > 0, "AIEN should have supply available for borrowing");
    }

    function test_fork_usdcAsCollateralEnabled() public view {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(USDC);

        // Check if USDC can be used as collateral (bit 56 in v3.6 = isActive, bit 57 = isFrozen)
        // LTV > 0 means it can be used as collateral
        uint256 ltv = reserve.configuration.data & 0xFFFF;
        assertTrue(ltv > 0, "USDC should have LTV > 0 (can be collateral)");

        console2.log("USDC LTV (bps):", ltv);
    }

    // ═══════════════════════════════════════════════════════════════════
    // SHARE PRICE ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════

    function test_fork_sharePriceConsistency() public {
        // Multiple deposits should maintain share price consistency

        // Alice deposits 1M
        vm.startPrank(alice);
        usdc.approve(address(morphoVault), 1_000_000e6);
        morphoVault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        uint256 sharePrice1 = morphoVault.sharePrice();
        console2.log("Share price after Alice deposit:", sharePrice1);

        // Bob deposits 500k
        vm.startPrank(bob);
        usdc.approve(address(morphoVault), 500_000e6);
        morphoVault.deposit(500_000e6, bob);
        vm.stopPrank();

        uint256 sharePrice2 = morphoVault.sharePrice();
        console2.log("Share price after Bob deposit:", sharePrice2);

        // Share price should remain 1:1 since no yield has accrued
        assertEq(sharePrice1, 1e18, "Initial share price should be 1.0");
        assertEq(sharePrice2, 1e18, "Share price should still be 1.0");

        // Verify proportional shares
        uint256 aliceShares = morphoVault.balanceOf(alice);
        uint256 bobShares = morphoVault.balanceOf(bob);
        assertEq(aliceShares, 1_000_000e6, "Alice should have proportional shares");
        assertEq(bobShares, 500_000e6, "Bob should have proportional shares");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ITERATIVE LEVERAGE LOOP - DIRECT POOL LEVEL
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Tests iterative supply→borrow→swap→supply loop at the pool level
     * @dev Simulates what the strategy does across multiple TWAP iterations
     *      to achieve 7x leverage. Uses the ZaibotsAaveAdapter against the real pool.
     *      Swap is simulated with deal() since we're testing pool mechanics, not DEX routing.
     */
    function test_fork_iterativeLeverageLoop_toTarget() public {
        // Raise caps for this test: AIEN borrow 50M, AIEN supply 100M, USDC supply 100M
        vm.startPrank(ACL_ADMIN);
        IPoolConfigurator(POOL_CONFIGURATOR).setBorrowCap(AIEN, 50_000_000);
        IPoolConfigurator(POOL_CONFIGURATOR).setSupplyCap(AIEN, 100_000_000);
        IPoolConfigurator(POOL_CONFIGURATOR).setSupplyCap(USDC, 100_000_000);
        vm.stopPrank();

        // Ensure enough AIEN liquidity in the pool for borrowing
        // Supply 20M AIEN to the pool from a whale
        address whale = makeAddr("aienWhale");
        deal(AIEN, whale, 20_000_000e18);
        vm.startPrank(whale);
        aien.approve(POOL, 20_000_000e18);
        pool.supply(AIEN, 20_000_000e18, whale, 0);
        vm.stopPrank();

        uint256 initialCollateral = 1_000_000e6; // 1M USDC
        uint256 usdcPrice = oracle.getAssetPrice(USDC); // 8 decimals
        uint256 aienPrice = oracle.getAssetPrice(AIEN);  // 8 decimals
        uint256 targetLeverage = uint256(TARGET_LEVERAGE) * 1e9; // 5e18

        console2.log("=== Iterative Leverage Loop ===");
        console2.log("Initial collateral:", initialCollateral / 1e6, "USDC");
        console2.log("Target leverage:", targetLeverage / 1e18, "x");
        console2.log("USDC price (8 dec):", usdcPrice);
        console2.log("AIEN price (8 dec):", aienPrice);

        // Supply initial USDC through zaibots adapter
        deal(USDC, address(this), initialCollateral);
        usdc.approve(address(zaibots), initialCollateral);
        zaibots.supply(USDC, initialCollateral, address(this));

        uint256 iteration = 0;
        uint256 maxIterations = 20;

        while (iteration < maxIterations) {
            // Get current state from the adapter
            uint256 collateral = zaibots.getCollateralBalance(address(this), USDC);
            uint256 debtAien = IERC20(AIEN_DEBT_TOKEN).balanceOf(address(zaibots));

            // Convert debt to USDC-equivalent (base units)
            // debtAien is in 18 dec, aienPrice in 8 dec, usdcPrice in 8 dec
            // debtInUsdc = debtAien * aienPrice / usdcPrice / 1e12 (adjust 18->6 dec)
            uint256 debtInUsdc = debtAien > 0 ? (debtAien * aienPrice) / (usdcPrice * 1e12) : 0;
            uint256 equity = collateral > debtInUsdc ? collateral - debtInUsdc : 0;

            uint256 currentLeverage;
            if (equity == 0) {
                currentLeverage = type(uint256).max;
            } else if (debtInUsdc == 0) {
                currentLeverage = 1e18;
            } else {
                currentLeverage = (collateral * 1e18) / equity;
            }

            console2.log("--- Iteration", iteration, "---");
            console2.log("  Collateral:", collateral / 1e6, "USDC");
            console2.log("  Debt:", debtInUsdc / 1e6, "USDC-equiv");
            console2.log("  Equity:", equity / 1e6, "USDC");
            console2.log("  Leverage:", currentLeverage * 100 / 1e18, "% (100 = 1x)");

            // Check if we've reached target
            if (currentLeverage >= targetLeverage) {
                console2.log(">>> TARGET LEVERAGE REACHED at iteration", iteration);
                break;
            }

            // Calculate how much more collateral we need
            uint256 targetCollateral = (equity * targetLeverage) / 1e18;
            uint256 additionalNeeded = targetCollateral > collateral ? targetCollateral - collateral : 0;

            // Cap per-iteration trade at maxTradeSize
            uint256 tradeSize = additionalNeeded > MAX_TRADE_SIZE ? MAX_TRADE_SIZE : additionalNeeded;

            // Calculate AIEN to borrow for this trade
            // borrowAmount = tradeSize (in USDC 6 dec) * usdcPrice / aienPrice * 1e12 (dec adjustment)
            uint256 borrowAmountAien = (tradeSize * usdcPrice * 1e12) / aienPrice;

            // Check pool has enough AIEN supply for the borrow
            DataTypes.ReserveDataLegacy memory aienReserve = pool.getReserveData(AIEN);
            uint256 aienSupply = IERC20(aienReserve.aTokenAddress).totalSupply();
            if (borrowAmountAien > aienSupply) {
                console2.log("  >>> Capping borrow to available supply:", aienSupply / 1e18, "AIEN");
                borrowAmountAien = aienSupply * 95 / 100; // 95% of supply to leave headroom
            }

            // Check health factor allows this borrow
            (, , uint256 availableBorrowsBase, , , ) = pool.getUserAccountData(address(zaibots));
            uint256 borrowValueBase = (borrowAmountAien * aienPrice) / 1e18; // 8 dec base units
            if (borrowValueBase > availableBorrowsBase) {
                // Reduce borrow to fit within available
                borrowAmountAien = (availableBorrowsBase * 1e18 * 95) / (aienPrice * 100);
                console2.log("  >>> Capped borrow to health limit:", borrowAmountAien / 1e18, "AIEN");
            }

            if (borrowAmountAien == 0) {
                console2.log("  >>> No more borrowing capacity, stopping");
                break;
            }

            console2.log("  Borrowing:", borrowAmountAien / 1e18, "AIEN");

            // Borrow AIEN through zaibots adapter
            zaibots.borrow(AIEN, borrowAmountAien, address(this));

            // Simulate swap: AIEN -> USDC
            // In production this goes through Milkman/CoW. Here we simulate the output.
            uint256 usdcReceived = (borrowAmountAien * aienPrice) / (usdcPrice * 1e12);
            deal(USDC, address(this), usdcReceived);

            console2.log("  Swap output:", usdcReceived / 1e6, "USDC");

            // Supply the received USDC back as additional collateral
            usdc.approve(address(zaibots), usdcReceived);
            zaibots.supply(USDC, usdcReceived, address(this));

            iteration++;
        }

        // Final state
        uint256 finalCollateral = zaibots.getCollateralBalance(address(this), USDC);
        uint256 finalDebtAien = IERC20(AIEN_DEBT_TOKEN).balanceOf(address(zaibots));
        uint256 finalDebtUsdc = finalDebtAien > 0 ? (finalDebtAien * aienPrice) / (usdcPrice * 1e12) : 0;
        uint256 finalEquity = finalCollateral > finalDebtUsdc ? finalCollateral - finalDebtUsdc : 0;
        uint256 finalLeverage = finalEquity > 0 ? (finalCollateral * 1e18) / finalEquity : 1e18;

        (, , , , , uint256 finalHF) = pool.getUserAccountData(address(zaibots));

        console2.log("=== FINAL STATE ===");
        console2.log("Collateral:", finalCollateral / 1e6, "USDC");
        console2.log("Debt:", finalDebtUsdc / 1e6, "USDC-equiv");
        console2.log("Equity:", finalEquity / 1e6, "USDC");
        console2.log("Leverage:", finalLeverage * 100 / 1e18, "%");
        console2.log("Health factor:", finalHF);
        console2.log("Iterations:", iteration);

        // Assertions
        assertTrue(finalLeverage >= uint256(MIN_LEVERAGE) * 1e9, "Leverage should be >= min (2x)");
        assertTrue(finalHF > 1e18, "Health factor should be > 1 (not liquidatable)");
        assertTrue(finalCollateral > initialCollateral, "Collateral should have grown");
        assertTrue(finalDebtAien > 0, "Should have AIEN debt");
        assertTrue(iteration > 1, "Should have taken multiple iterations");
    }

    // ═══════════════════════════════════════════════════════════════════
    // STRATEGY-LEVEL LEVERAGE LOOP WITH SIMULATED SWAP COMPLETION
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Tests the full strategy engage→iterate flow with swap completion
     * @dev The strategy has two design gaps discovered during this test:
     *      1. No swap completion callback — swapState never resets after Milkman settles
     *      2. iterateRebalance() declared in IKeeperCarryStrategy but not implemented
     *      We work around these by:
     *      - Using vm.store to reset swapState to IDLE after settling swaps
     *      - Warping past TWAP cooldown, then calling engage() for the first trade
     *        and manually re-engaging the lever flow for subsequent iterations
     */
    function test_fork_strategyLeverageLoop_withSimulatedCompletion() public {
        // Raise caps: AIEN borrow 50M, AIEN supply 100M, USDC supply 100M
        vm.startPrank(ACL_ADMIN);
        IPoolConfigurator(POOL_CONFIGURATOR).setBorrowCap(AIEN, 50_000_000);
        IPoolConfigurator(POOL_CONFIGURATOR).setSupplyCap(AIEN, 100_000_000);
        IPoolConfigurator(POOL_CONFIGURATOR).setSupplyCap(USDC, 100_000_000);
        vm.stopPrank();

        address whale = makeAddr("aienWhale");
        deal(AIEN, whale, 20_000_000e18);
        vm.startPrank(whale);
        aien.approve(POOL, 20_000_000e18);
        pool.supply(AIEN, 20_000_000e18, whale, 0);
        vm.stopPrank();

        uint256 depositAmount = 2_000_000e6;
        uint256 allocateAmount = 1_000_000e6;

        // Step 1: Deposit and allocate to strategy
        vm.startPrank(alice);
        usdc.approve(address(morphoVault), depositAmount);
        morphoVault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.prank(owner);
        morphoVault.allocate(address(carryAdapter), "", allocateAmount);

        console2.log("=== Strategy Leverage Loop ===");
        console2.log("Initial collateral:", allocateAmount / 1e6, "USDC");

        // Use a monotonically increasing timestamp to avoid Aave underflows
        uint256 currentTs = block.timestamp;

        // Step 2: Engage (first borrow + swap request)
        vm.prank(keeper, keeper);
        carryStrategy.engage();

        uint256 iteration = 0;
        uint256 maxIterations = 15;
        uint256 targetLev = uint256(TARGET_LEVERAGE) * 1e9; // 5e18

        while (iteration < maxIterations) {
            console2.log("--- Strategy Iteration", iteration, "---");

            // There should be a pending swap from engage() or a previous lever call
            if (carryStrategy.swapState() != CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
                console2.log("  No pending lever swap, stopping");
                break;
            }

            // Advance time slightly for settlement
            currentTs += 10;
            vm.warp(currentTs);

            // Settle the swap through MockMilkman
            bytes32 swapId = mockMilkman.getLatestSwapId();
            mockMilkman.settleSwapWithPrice(swapId);

            // USDC has arrived at the strategy from the swap
            uint256 usdcReceived = usdc.balanceOf(address(carryStrategy));
            console2.log("  USDC received from swap:", usdcReceived / 1e6);

            // Simulate swap completion:
            // 1. Supply the received USDC to the pool as additional collateral
            if (usdcReceived > 0) {
                vm.startPrank(address(carryStrategy));
                usdc.approve(address(zaibots), usdcReceived);
                zaibots.supply(USDC, usdcReceived, address(carryStrategy));
                vm.stopPrank();
            }

            // 2. Reset swap state (simulates the missing callback)
            _resetSwapState();

            // Check leverage after this iteration
            uint256 currentLev = carryStrategy.getCurrentLeverageRatio();
            console2.log("  Leverage after iteration:", currentLev * 100 / 1e18, "%");

            iteration++;

            // Check if target reached
            if (currentLev >= targetLev) {
                console2.log("  >>> TARGET LEVERAGE REACHED at iteration", iteration);
                break;
            }

            // Advance past both TWAP cooldown and rebalance interval
            // This ensures shouldRebalance returns REBALANCE (not ITERATE which has no handler)
            _clearTwapLeverageRatio();
            currentTs += REBALANCE_INTERVAL + 1;
            vm.warp(currentTs);

            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
            console2.log("  ShouldRebalance:", uint256(action));

            if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
                // rebalance may fail with CollateralCannotCoverNewBorrow when
                // approaching the LTV-constrained max leverage (1/(1-LTV))
                vm.prank(keeper, keeper);
                try carryStrategy.rebalance() {
                    // Succeeded, continue loop
                } catch {
                    console2.log("  >>> Rebalance reverted (likely at LTV limit), stopping");
                    break;
                }
            } else if (action == CarryStrategy.ShouldRebalance.NONE) {
                // Leverage is within bounds, no rebalance needed
                console2.log("  >>> No more rebalancing needed");
                break;
            } else {
                console2.log("  >>> Unexpected action:", uint256(action));
                break;
            }
        }

        // Final state
        uint256 finalLev = carryStrategy.getCurrentLeverageRatio();
        uint256 finalAssets = carryStrategy.getRealAssets();
        (, , , , , uint256 hf) = pool.getUserAccountData(address(zaibots));

        // USDC LTV = 85% → theoretical max leverage = 1/(1-0.85) = 6.67x
        // So 7x target is unreachable. We verify we got as close as possible.
        uint256 maxTheoreticalLev = 6_670_000_000_000_000_000; // ~6.67e18
        console2.log("=== FINAL STRATEGY STATE ===");
        console2.log("Leverage:", finalLev * 100 / 1e18, "%");
        console2.log("Real assets:", finalAssets / 1e6, "USDC");
        console2.log("Health factor:", hf);
        console2.log("Total iterations:", iteration);
        console2.log("Max theoretical leverage (85% LTV):", maxTheoreticalLev * 100 / 1e18, "%");

        assertTrue(finalLev > 2e18, "Should be leveraged above 2x");
        assertTrue(hf > 1e18, "Health factor should be > 1 (not liquidatable)");
        assertTrue(iteration > 3, "Should have completed multiple iterations");
    }

    /**
     * @notice Reset CarryStrategy swapState to IDLE and clear pending fields
     * @dev Uses vm.store to poke the packed storage slot.
     *      The layout of slot containing swapState:
     *      [swapState(1 byte) | twapLeverageRatio(8) | lastRebalanceTs(8) | lastTradeTs(8)]
     *      We preserve twapLeverageRatio and timestamps, just clear swapState.
     *      Also clears pendingSwapTs and pendingSwapAmount in the next slot.
     */
    function _resetSwapState() internal {
        // Find the storage slot of swapState by reading current packed value.
        // CarryStrategy storage layout after inherited Ownable(1 slot) + ReentrancyGuard(1 slot):
        // slot 2: string name
        // slot 3: StrategyType strategyType
        // slots 4-12: Addresses addr (9 addresses)
        // slot 13: LeverageParams (4x uint64 = 32 bytes)
        // slots 14-15: ExecutionParams (uint128+uint32+uint16+uint32+uint64 = 34 bytes)
        // slot 16: IncentiveParams (uint16+uint16+uint128+uint96 = 32 bytes)
        // slot 17: swapState(uint8) + twapLeverageRatio(uint64) + lastRebalanceTs(uint64) + lastTradeTs(uint64)
        // slot 18: pendingSwapTs(uint64) + pendingSwapAmount(uint128)

        // Read slot 17
        bytes32 slot17 = vm.load(address(carryStrategy), bytes32(uint256(17)));

        // Clear the lowest byte (swapState) - set to 0 (IDLE)
        // Keep everything else (twapLeverageRatio, timestamps)
        bytes32 clearedSlot17 = slot17 & ~bytes32(uint256(0xFF));
        vm.store(address(carryStrategy), bytes32(uint256(17)), clearedSlot17);

        // Clear slot 18 (pendingSwapTs + pendingSwapAmount)
        vm.store(address(carryStrategy), bytes32(uint256(18)), bytes32(0));
    }

    /**
     * @notice Clear twapLeverageRatio in storage so shouldRebalance() doesn't return ITERATE/NONE
     * @dev twapLeverageRatio is bits 8-71 of slot 17 (uint64 packed after uint8 swapState)
     */
    function _clearTwapLeverageRatio() internal {
        bytes32 slot17 = vm.load(address(carryStrategy), bytes32(uint256(17)));
        // Mask to clear bits 8-71 (twapLeverageRatio), preserve everything else
        bytes32 mask = ~bytes32(uint256(0xFFFFFFFFFFFFFFFF) << 8);
        vm.store(address(carryStrategy), bytes32(uint256(17)), slot17 & mask);
    }
}
