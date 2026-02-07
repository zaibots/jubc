// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Shared test utilities
import {MockERC20, TestConstants, NetworkConfig} from "../../../lib/TestUtils.sol";

// Morpho Vault V2
import {VaultV2} from "vault-v2/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";

// Aave V3 interfaces (for Zaibots)
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol";
import {IAaveOracle} from "aave-v3-origin/contracts/interfaces/IAaveOracle.sol";

// Carry strategy contracts
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";
import {CarryAdapter} from "custom/integrations/morpho/adapters/CarryAdapter.sol";
import {LinearBlockTwapOracle} from "custom/products/carryUSDC/LinearBlockTwapOracle.sol";
import {CarryTwapPriceChecker} from "custom/products/carryUSDC/CarryTwapPriceChecker.sol";
import {CarryKeeper} from "custom/products/carryUSDC/CarryKeeper.sol";

// Test-specific mocks (for scenario simulation only)
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockMilkman} from "../mocks/MockMilkman.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title TestCarryUSDBase
 * @notice Base test contract for CarryUSD Morpho integration tests
 * @dev Uses forking for mission-critical integrations (Morpho, Zaibots/Aave)
 *      Only uses mocks for test scenario simulation (price manipulation, swap behavior)
 *
 * MODES:
 * - Fork mode (NETWORK=mainnet|sepolia): Tests against real deployed contracts
 * - Local mode (NETWORK=local): Uses minimal mocks for rapid unit testing
 *
 * ARCHITECTURE:
 * ─────────────────────────────────────────────────────────────
 * │ TestCarryUSDBase (this contract)                          │
 * │   ├── Real Contracts (via forking)                        │
 * │   │   ├── Zaibots Pool (Aave V3)                         │
 * │   │   ├── Morpho Vault (when deployed)                    │
 * │   │   └── Production tokens (USDC, jUBC)                  │
 * │   ├── Strategy Contracts (deployed fresh in tests)        │
 * │   │   ├── CarryStrategy                                   │
 * │   │   ├── CarryAdapter                                    │
 * │   │   ├── LinearBlockTwapOracle                          │
 * │   │   ├── CarryTwapPriceChecker                          │
 * │   │   └── CarryKeeper                                     │
 * │   ├── Test Mocks (for scenario simulation)                │
 * │   │   ├── MockChainlinkFeed (price manipulation)          │
 * │   │   └── MockMilkman (swap behavior simulation)          │
 * │   └── Helper Functions                                    │
 * ─────────────────────────────────────────────────────────────
 */
abstract contract TestCarryUSDBase is Test {
    // ═══════════════════════════════════════════════════════════════════
    // TEST ACTORS
    // ═══════════════════════════════════════════════════════════════════

    address public owner = makeAddr("owner");
    address public keeper = makeAddr("keeper");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    // ═══════════════════════════════════════════════════════════════════
    // CARRY-SPECIFIC CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    // Leverage params (9 decimals - matches CarryStrategy.DECIMALS)
    uint64 constant CONSERVATIVE_TARGET = 2_500_000_000;  // 2.5x
    uint64 constant CONSERVATIVE_MIN = 2_000_000_000;     // 2x
    uint64 constant CONSERVATIVE_MAX = 3_000_000_000;     // 3x
    uint64 constant CONSERVATIVE_RIPCORD = 3_500_000_000; // 3.5x

    uint64 constant MODERATE_TARGET = 5_000_000_000;      // 5x
    uint64 constant MODERATE_MIN = 4_000_000_000;         // 4x
    uint64 constant MODERATE_MAX = 6_000_000_000;         // 6x
    uint64 constant MODERATE_RIPCORD = 7_000_000_000;     // 7x

    uint64 constant AGGRESSIVE_TARGET = 10_000_000_000;   // 10x
    uint64 constant AGGRESSIVE_MIN = 8_000_000_000;       // 8x
    uint64 constant AGGRESSIVE_MAX = 12_000_000_000;      // 12x
    uint64 constant AGGRESSIVE_RIPCORD = 14_000_000_000;  // 14x

    // Execution params
    uint128 constant DEFAULT_MAX_TRADE_SIZE = 100_000e6;  // 100k USDC
    uint32 constant DEFAULT_TWAP_COOLDOWN = 5 minutes;
    uint16 constant DEFAULT_SLIPPAGE_BPS = 50;            // 0.5%
    uint32 constant DEFAULT_REBALANCE_INTERVAL = 4 hours;
    uint64 constant DEFAULT_RECENTER_SPEED = 500_000_000; // 50% (9 decimals)

    // Incentive params
    uint16 constant DEFAULT_RIPCORD_SLIPPAGE_BPS = 200;   // 2%
    uint16 constant DEFAULT_RIPCORD_COOLDOWN = 2 minutes;
    uint128 constant DEFAULT_RIPCORD_MAX_TRADE = 50_000e6; // 50k USDC
    uint96 constant DEFAULT_ETH_REWARD = 1 ether;

    // Price constant (8 decimals - Chainlink standard)
    int256 constant BASE_JPY_PRICE = TestConstants.JPY_USD_PRICE;

    // Precision constants
    uint256 constant PRECISE_UNIT = 1e9;
    uint256 constant FULL_PRECISION = 1e18;

    // ═══════════════════════════════════════════════════════════════════
    // STRESS TEST MATRIX PARAMETERS
    // ═══════════════════════════════════════════════════════════════════

    uint256 constant PERCENT_0_1 = 10;
    uint256 constant PERCENT_1 = 100;
    uint256 constant PERCENT_5 = 500;
    uint256 constant PERCENT_10 = 1000;
    uint256 constant PERCENT_20 = 2000;

    uint256 constant SIZE_100 = 100e6;
    uint256 constant SIZE_10K = 10_000e6;
    uint256 constant SIZE_1M = 1_000_000e6;
    uint256 constant SIZE_100M = 100_000_000e6;
    uint256 constant SIZE_100B = 100_000_000_000e6;

    uint256 constant VAULT_10M = 10_000_000e6;
    uint256 constant VAULT_100M = 100_000_000e6;
    uint256 constant VAULT_1B = 1_000_000_000e6;
    uint256 constant VAULT_10B = 10_000_000_000e6;
    uint256 constant VAULT_100B = 100_000_000_000e6;

    int256 constant YEN_UP_30 = 3000;
    int256 constant YEN_UP_10 = 1000;
    int256 constant YEN_UP_5 = 500;
    int256 constant YEN_DOWN_5 = -500;
    int256 constant YEN_DOWN_10 = -1000;
    int256 constant YEN_DOWN_30 = -3000;

    // ═══════════════════════════════════════════════════════════════════
    // PROTOCOL STATE (REAL CONTRACTS VIA FORKING)
    // ═══════════════════════════════════════════════════════════════════

    IPool public zaibots;
    IPoolAddressesProvider public addressesProvider;
    IAaveOracle public aaveOracle;

    IERC20 public usdc;
    IERC20 public jUBC;

    VaultV2 public vaultV2;
    address public morphoVault;

    // ═══════════════════════════════════════════════════════════════════
    // CARRY STRATEGY CONTRACTS
    // ═══════════════════════════════════════════════════════════════════

    CarryStrategy public carryStrategy;
    CarryAdapter public carryAdapter;
    LinearBlockTwapOracle public twapOracle;
    CarryTwapPriceChecker public priceChecker;
    CarryKeeper public carryKeeper;

    // ═══════════════════════════════════════════════════════════════════
    // TEST MOCKS (FOR SCENARIO SIMULATION)
    // ═══════════════════════════════════════════════════════════════════

    MockChainlinkFeed public mockJpyUsdFeed;
    MockMilkman public mockMilkman;
    MockAavePool public mockPool;
    MockERC20 public mockUsdc;
    MockERC20 public mockJUBC;

    // ═══════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════

    struct CarryConfig {
        address zaibots;
        address usdc;
        address jUBC;
        address jpyUsdFeed;
        address milkman;
        address morphoVault;
        bool isForked;
    }

    CarryConfig public config;

    event CarrySetupComplete(address strategy, address adapter, bool forked);

    // ═══════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        string memory network = vm.envOr("NETWORK", string("local"));

        if (_isForkedNetwork(network)) {
            _setupFork(network);
        } else {
            _setupLocal();
        }

        _deployCarryContracts();
        _setupCarryPermissions();
        _labelAddresses();
        _fundTestUsers();

        emit CarrySetupComplete(address(carryStrategy), address(carryAdapter), config.isForked);
    }

    function _isForkedNetwork(string memory network) internal pure returns (bool) {
        return keccak256(bytes(network)) == keccak256(bytes("mainnet")) ||
               keccak256(bytes(network)) == keccak256(bytes("sepolia")) ||
               keccak256(bytes(network)) == keccak256(bytes("base"));
    }

    // ═══════════════════════════════════════════════════════════════════
    // FORK SETUP
    // ═══════════════════════════════════════════════════════════════════

    function _setupFork(string memory network) internal virtual {
        config.isForked = true;

        if (keccak256(bytes(network)) == keccak256(bytes("sepolia"))) {
            _setupSepoliaFork();
        } else if (keccak256(bytes(network)) == keccak256(bytes("mainnet"))) {
            _setupMainnetFork();
        } else {
            revert("Unsupported network");
        }
    }

    function _setupSepoliaFork() internal {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        require(bytes(rpcUrl).length > 0, "SEPOLIA_RPC_URL not set");
        vm.createSelectFork(rpcUrl);

        NetworkConfig.SepoliaAddresses memory addrs = NetworkConfig.getSepolia();

        addressesProvider = IPoolAddressesProvider(addrs.poolAddressesProvider);
        zaibots = IPool(addrs.pool);
        aaveOracle = IAaveOracle(addrs.oracle);
        usdc = IERC20(addrs.usdc);

        address jUBCAddr = vm.envOr("JUBC_TOKEN", address(0));
        if (jUBCAddr != address(0)) {
            jUBC = IERC20(jUBCAddr);
        } else {
            mockJUBC = new MockERC20("Japanese UBI Coin", "jUBC", 18);
            jUBC = IERC20(address(mockJUBC));
        }

        mockJpyUsdFeed = new MockChainlinkFeed(8, "JPY / USD", BASE_JPY_PRICE);
        mockMilkman = new MockMilkman();
        _setupMilkmanPrices();

        config = CarryConfig({
            zaibots: address(zaibots),
            usdc: address(usdc),
            jUBC: address(jUBC),
            jpyUsdFeed: address(mockJpyUsdFeed),
            milkman: address(mockMilkman),
            morphoVault: vm.envOr("MORPHO_VAULT", address(0)),
            isForked: true
        });
    }

    function _setupMainnetFork() internal {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        require(bytes(rpcUrl).length > 0, "ETH_RPC_URL not set");
        vm.createSelectFork(rpcUrl);

        NetworkConfig.MainnetAddresses memory addrs = NetworkConfig.getMainnet();

        usdc = IERC20(addrs.usdc);
        mockJpyUsdFeed = new MockChainlinkFeed(8, "JPY / USD", BASE_JPY_PRICE);
        mockMilkman = new MockMilkman();
        _setupMilkmanPrices();

        address zaibotsAddr = vm.envOr("ZAIBOTS_POOL", address(0));
        if (zaibotsAddr != address(0)) {
            zaibots = IPool(zaibotsAddr);
        }

        config = CarryConfig({
            zaibots: address(zaibots),
            usdc: address(usdc),
            jUBC: vm.envOr("JUBC_TOKEN", address(0)),
            jpyUsdFeed: address(mockJpyUsdFeed),
            milkman: address(mockMilkman),
            morphoVault: vm.envOr("MORPHO_VAULT", address(0)),
            isForked: true
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // LOCAL SETUP
    // ═══════════════════════════════════════════════════════════════════

    function _setupLocal() internal virtual {
        config.isForked = false;

        vm.startPrank(owner);

        mockUsdc = new MockERC20("USD Coin", "USDC", 6);
        mockJUBC = new MockERC20("Japanese UBI Coin", "jUBC", 18);

        usdc = IERC20(address(mockUsdc));
        jUBC = IERC20(address(mockJUBC));

        mockJpyUsdFeed = new MockChainlinkFeed(8, "JPY / USD", BASE_JPY_PRICE);
        mockMilkman = new MockMilkman();
        mockPool = new MockAavePool();
        mockPool.initReserve(address(mockUsdc));
        mockPool.initReserve(address(mockJUBC));
        mockPool.setLTV(address(mockUsdc), address(mockJUBC), 0.75e18);
        mockPool.configureBorrowPair(address(mockJUBC), address(mockUsdc), address(mockJpyUsdFeed));
        _setupMilkmanPrices();

        vm.stopPrank();

        config = CarryConfig({
            zaibots: address(mockPool),
            usdc: address(usdc),
            jUBC: address(jUBC),
            jpyUsdFeed: address(mockJpyUsdFeed),
            milkman: address(mockMilkman),
            morphoVault: address(0),
            isForked: false
        });
    }

    function _setupMilkmanPrices() internal {
        // jUBC (18 dec) -> USDC (6 dec): price = oraclePrice / 100
        // At BASE_JPY_PRICE=650000 (8 dec, $0.0065/JPY): 1 jUBC = 6500 USDC units = $0.0065
        mockMilkman.setMockPrice(address(jUBC), address(usdc), 6500);
        // USDC (6 dec) -> jUBC (18 dec): price = 1e38 / oraclePrice
        // At BASE_JPY_PRICE=650000: 1 USDC (1e6 units) -> 153.85 jUBC (1.5385e20 units)
        // MockMilkman formula: output = (amountIn * mockPrice) / 1e18
        // So: 1.5385e20 = (1e6 * mockPrice) / 1e18 => mockPrice = 1.5385e32
        mockMilkman.setMockPrice(address(usdc), address(jUBC), 1e38 / uint256(BASE_JPY_PRICE));
    }

    // ═══════════════════════════════════════════════════════════════════
    // STRATEGY DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════

    function _deployCarryContracts() internal virtual {
        vm.startPrank(owner);

        twapOracle = new LinearBlockTwapOracle(config.jpyUsdFeed);

        priceChecker = new CarryTwapPriceChecker(
            address(twapOracle),
            config.jpyUsdFeed,
            config.usdc,
            config.jUBC
        );

        CarryStrategy.Addresses memory strategyAddresses = CarryStrategy.Addresses({
            adapter: address(0),
            zaibots: config.zaibots != address(0) ? config.zaibots : address(1),
            collateralToken: config.usdc,
            debtToken: config.jUBC,
            jpyUsdOracle: config.jpyUsdFeed,
            jpyUsdAggregator: address(0),
            twapOracle: address(twapOracle),
            milkman: config.milkman,
            priceChecker: address(priceChecker)
        });

        CarryStrategy.ExecutionParams memory execParams = CarryStrategy.ExecutionParams({
            maxTradeSize: DEFAULT_MAX_TRADE_SIZE,
            twapCooldown: DEFAULT_TWAP_COOLDOWN,
            slippageBps: DEFAULT_SLIPPAGE_BPS,
            rebalanceInterval: DEFAULT_REBALANCE_INTERVAL,
            recenterSpeed: DEFAULT_RECENTER_SPEED
        });

        CarryStrategy.IncentiveParams memory incParams = CarryStrategy.IncentiveParams({
            slippageBps: DEFAULT_RIPCORD_SLIPPAGE_BPS,
            twapCooldown: DEFAULT_RIPCORD_COOLDOWN,
            maxTrade: DEFAULT_RIPCORD_MAX_TRADE,
            etherReward: DEFAULT_ETH_REWARD
        });

        carryStrategy = new CarryStrategy(
            "Conservative Carry (2.5x)",
            CarryStrategy.StrategyType.CONSERVATIVE,
            strategyAddresses,
            [CONSERVATIVE_TARGET, CONSERVATIVE_MIN, CONSERVATIVE_MAX, CONSERVATIVE_RIPCORD],
            execParams,
            incParams
        );

        // Deploy real VaultV2 via factory (or use provided address for fork mode)
        if (config.morphoVault == address(0)) {
            VaultV2Factory factory = new VaultV2Factory();
            address vaultAddr = factory.createVaultV2(owner, config.usdc, bytes32("test-carry"));
            vaultV2 = VaultV2(vaultAddr);
            morphoVault = vaultAddr;
        } else {
            morphoVault = config.morphoVault;
            vaultV2 = VaultV2(morphoVault);
        }

        carryAdapter = new CarryAdapter(
            morphoVault,
            config.usdc,
            "conservative-usdc",
            address(twapOracle)
        );

        carryAdapter.setStrategy(address(carryStrategy));
        carryStrategy.setAdapter(address(carryAdapter));

        // Configure VaultV2: curator, adapter, allocator, caps
        _configureVaultV2();

        carryKeeper = new CarryKeeper();
        carryKeeper.addStrategy(address(carryStrategy));

        vm.deal(address(carryStrategy), 10 ether);

        vm.stopPrank();
    }

    function _configureVaultV2() internal {
        vaultV2.setCurator(owner);

        // Submit + execute (zero timelock on fresh vaults)
        vaultV2.submit(abi.encodeCall(IVaultV2.addAdapter, (address(carryAdapter))));
        vaultV2.addAdapter(address(carryAdapter));

        vaultV2.submit(abi.encodeCall(IVaultV2.setIsAllocator, (owner, true)));
        vaultV2.setIsAllocator(owner, true);

        uint256 maxCap = uint256(type(uint128).max);
        _setAbsoluteCap(bytes("aave-protocol"), maxCap);
        _setAbsoluteCap(bytes("jpy-fx-exposure"), maxCap);
        _setAbsoluteCap(abi.encodePacked("strategy:", "conservative-usdc"), maxCap);
    }

    function _setAbsoluteCap(bytes memory idData, uint256 cap) internal {
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, cap)));
        vaultV2.increaseAbsoluteCap(idData, cap);
    }

    /// @notice Allocate assets from VaultV2 to the carry adapter
    function _vaultAllocate(uint256 assets) internal {
        vm.prank(owner);
        vaultV2.allocate(address(carryAdapter), "", assets);
    }

    /// @notice Deposit assets into VaultV2 and allocate to carry adapter
    function _vaultDepositAndAllocate(address depositor, uint256 depositAmount, uint256 allocateAmount) internal {
        vm.startPrank(depositor);
        IERC20(config.usdc).approve(address(vaultV2), depositAmount);
        vaultV2.deposit(depositAmount, depositor);
        vm.stopPrank();

        _vaultAllocate(allocateAmount);
    }

    function _setupCarryPermissions() internal virtual {
        vm.startPrank(owner);

        carryStrategy.setOperator(keeper);
        carryStrategy.setAllowedCaller(keeper, true);
        carryStrategy.setAllowedCaller(alice, true);
        carryStrategy.setAllowedCaller(bob, true);

        vm.stopPrank();
    }

    function _labelAddresses() internal virtual {
        vm.label(owner, "Owner");
        vm.label(keeper, "Keeper");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(address(usdc), "USDC");
        vm.label(address(jUBC), "jUBC");
        vm.label(address(carryStrategy), "CarryStrategy");
        vm.label(address(carryAdapter), "CarryAdapter");
        vm.label(address(twapOracle), "TwapOracle");
        vm.label(address(priceChecker), "PriceChecker");
        vm.label(address(carryKeeper), "CarryKeeper");
        vm.label(address(mockJpyUsdFeed), "MockJpyUsdFeed");
        vm.label(address(mockMilkman), "MockMilkman");
        if (address(vaultV2) != address(0)) {
            vm.label(address(vaultV2), "VaultV2");
        }
        if (address(zaibots) != address(0)) {
            vm.label(address(zaibots), "Zaibots");
        }
        if (address(mockPool) != address(0)) {
            vm.label(address(mockPool), "MockAavePool");
        }
    }

    function _fundTestUsers() internal virtual {
        if (!config.isForked) {
            mockUsdc.mint(alice, 100_000_000e6);
            mockUsdc.mint(bob, 100_000_000e6);
            mockUsdc.mint(charlie, 100_000_000e6);
            mockUsdc.mint(address(mockMilkman), 1_000_000_000_000e6);
            mockJUBC.mint(address(mockMilkman), 1_000_000_000_000e18);
            // Fund MockAavePool with jUBC for borrow liquidity
            mockJUBC.mint(address(mockPool), 1_000_000_000_000e18);
        } else {
            deal(address(usdc), alice, 100_000_000e6);
            deal(address(usdc), bob, 100_000_000e6);
            deal(address(usdc), charlie, 100_000_000e6);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════

    modifier onlyFork() {
        if (!config.isForked) {
            vm.skip(true);
        }
        _;
    }

    modifier onlyLocal() {
        if (config.isForked) {
            vm.skip(true);
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    function _calculateLeverageRatio(uint256 collateral, uint256 debtInBase) internal pure returns (uint256) {
        if (collateral == 0) return FULL_PRECISION;
        if (debtInBase == 0) return FULL_PRECISION;
        uint256 equity = collateral > debtInBase ? collateral - debtInBase : 0;
        if (equity == 0) return type(uint256).max;
        return (collateral * FULL_PRECISION) / equity;
    }

    function _convertJpyToUsdc(uint256 jUBCAmount, int256 jpyUsdPrice) internal pure returns (uint256) {
        return (jUBCAmount * uint256(jpyUsdPrice)) / 1e20;
    }

    function _convertUsdcToJpy(uint256 usdcAmount, int256 jpyUsdPrice) internal pure returns (uint256) {
        return (usdcAmount * 1e20) / uint256(jpyUsdPrice);
    }

    function _getLeverageFromStrategy() internal view returns (uint256) {
        return carryStrategy.getCurrentLeverageRatio();
    }

    function _getRealAssetsFromStrategy() internal view returns (uint256) {
        return carryStrategy.getRealAssets();
    }

    function _engageStrategy() internal {
        vm.prank(keeper, keeper);
        carryStrategy.engage();
    }

    function _triggerRebalance() internal {
        vm.prank(keeper, keeper);
        carryStrategy.rebalance();
    }

    function _iterateRebalance() internal {
        vm.prank(keeper, keeper);
        carryStrategy.iterateRebalance();
    }

    function _triggerRipcord(address caller) internal {
        vm.prank(caller, caller);
        carryStrategy.ripcord();
    }

    function _completeLeverSwap() internal {
        bytes32 swapId = mockMilkman.getLatestSwapId();
        mockMilkman.settleSwapWithPrice(swapId);
        carryStrategy.completeSwap();
    }

    function _completeDeleverSwap() internal {
        bytes32 swapId = mockMilkman.getLatestSwapId();
        mockMilkman.settleSwapWithPrice(swapId);
        carryStrategy.completeSwap();
    }

    function _setOraclePrice(int256 price) internal {
        mockJpyUsdFeed.setPrice(price);
    }

    function _applyPriceChange(int256 bpsChange) internal {
        mockJpyUsdFeed.applyPercentageChange(bpsChange);
    }

    function _applyYenMovement(int256 movementBps) internal {
        _applyPriceChange(movementBps);
    }

    function _makeOracleStale() internal {
        mockJpyUsdFeed.setStale(true);
    }

    function _simulatePriceSpike(int256 spikeAmount) internal {
        mockJpyUsdFeed.simulatePriceSpike(spikeAmount);
    }

    function _warpBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 12);
    }

    function _warpToRebalanceWindow() internal {
        vm.warp(block.timestamp + DEFAULT_REBALANCE_INTERVAL + 1);
    }

    function _warpPastTwapCooldown() internal {
        vm.warp(block.timestamp + DEFAULT_TWAP_COOLDOWN + 1);
    }

    function _warpPastSwapTimeout() internal {
        vm.warp(block.timestamp + 30 minutes + 1);
    }

    function _setMilkmanFailPriceCheck(bool shouldFail) internal {
        mockMilkman.setShouldFailPriceCheck(shouldFail);
    }

    function _setSwapSlippage(uint256 multiplier) internal {
        mockMilkman.setOutputMultiplier(multiplier);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ASSERTION HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _assertLeverageInRange(uint256 minLev, uint256 maxLev) internal view {
        uint256 currentLev = _getLeverageFromStrategy();
        assertGe(currentLev, minLev, "Leverage below min");
        assertLe(currentLev, maxLev, "Leverage above max");
    }

    function _assertNoSwapPending() internal view {
        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Swap should not be pending");
    }

    function _assertSwapState(CarryStrategy.SwapState expected) internal view {
        assertEq(uint256(carryStrategy.swapState()), uint256(expected), "Unexpected swap state");
    }

    function _assertRealAssetsMatch(uint256 toleranceBps) internal view {
        uint256 adapterAssets = carryAdapter.realAssets();
        uint256 strategyAssets = carryStrategy.getRealAssets();
        uint256 tolerance = (adapterAssets * toleranceBps) / 10000;
        uint256 diff = adapterAssets > strategyAssets ? adapterAssets - strategyAssets : strategyAssets - adapterAssets;
        assertLe(diff, tolerance, "Real assets mismatch exceeds tolerance");
    }

    function _assertIsEngaged() internal view {
        assertTrue(carryStrategy.isEngaged(), "Strategy should be engaged");
    }

    function _assertNotEngaged() internal view {
        assertFalse(carryStrategy.isEngaged(), "Strategy should not be engaged");
    }

    // ═══════════════════════════════════════════════════════════════════
    // STRESS TEST HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _getVaultPercentages() internal pure returns (uint256[] memory) {
        uint256[] memory p = new uint256[](5);
        p[0] = PERCENT_0_1; p[1] = PERCENT_1; p[2] = PERCENT_5; p[3] = PERCENT_10; p[4] = PERCENT_20;
        return p;
    }

    function _getDollarSizes() internal pure returns (uint256[] memory) {
        uint256[] memory s = new uint256[](5);
        s[0] = SIZE_100; s[1] = SIZE_10K; s[2] = SIZE_1M; s[3] = SIZE_100M; s[4] = SIZE_100B;
        return s;
    }

    function _getVaultSizes() internal pure returns (uint256[] memory) {
        uint256[] memory s = new uint256[](5);
        s[0] = VAULT_10M; s[1] = VAULT_100M; s[2] = VAULT_1B; s[3] = VAULT_10B; s[4] = VAULT_100B;
        return s;
    }

    function _getYenMovements() internal pure returns (int256[] memory) {
        int256[] memory m = new int256[](6);
        m[0] = YEN_UP_30; m[1] = YEN_UP_10; m[2] = YEN_UP_5; m[3] = YEN_DOWN_5; m[4] = YEN_DOWN_10; m[5] = YEN_DOWN_30;
        return m;
    }
}
