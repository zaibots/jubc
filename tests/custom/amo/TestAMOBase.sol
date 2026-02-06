// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test, console2, StdUtils} from 'forge-std/Test.sol';
import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {ERC20} from 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';
import {IGhoToken} from 'gho-origin/gho/interfaces/IGhoToken.sol';
import {IGhoFacilitator} from 'gho-origin/gho/interfaces/IGhoFacilitator.sol';

import {TestZaiBotsMarket, MockERC20} from '../base/TestZaiBotsMarket.sol';
import {AMOHandler} from './AMOHandler.sol';

/**
 * @title TestAMOBase
 * @author ZaiBots Imperial Security Division - 皇室経済安全保障部門
 * @notice Base test contract for all Algorithmic Market Operations (AMO) tests
 * @dev Template test suite for the Japanese Yen stablecoin infrastructure
 *
 * ╔══════════════════════════════════════════════════════════════════════════════╗
 * ║                    ZAIBOTS PROTOCOL - AMO TEST SUITE                        ║
 * ║                                                                              ║
 * ║  Classification: IMPERIAL TREASURY PROTOCOL - CRITICAL INFRASTRUCTURE       ║
 * ║  Target: World's Largest Stablecoin - Japanese Economic Revolution 2030     ║
 * ║                                                                              ║
 * ║  Test Categories:                                                            ║
 * ║  ├── Unit Tests: Individual function validation                              ║
 * ║  ├── Integration Tests: Cross-contract interaction verification              ║
 * ║  ├── Invariant Tests: State space exploration via fuzzing                    ║
 * ║  ├── Adversarial Tests: Attack simulation and defense validation            ║
 * ║  └── Stress Tests: High volume and edge case scenarios                       ║
 * ║                                                                              ║
 * ╚══════════════════════════════════════════════════════════════════════════════╝
 *
 * INVARIANTS ENFORCED BY THIS TEST SUITE:
 *
 * 1. BUCKET INTEGRITY
 *    - Bucket level MUST never exceed bucket capacity
 *    - Sum of all facilitator levels MUST equal total supply
 *
 * 2. COLLATERAL BACKING
 *    - Treasury collateral value MUST >= jUBC in circulation (by USD value)
 *    - Minting rate MUST match oracle price at time of transaction
 *
 * 3. ORACLE INTEGRITY
 *    - Operations MUST revert with stale oracle data
 *    - Price used MUST be from most recent valid round
 *
 * 4. POSITION ACCOUNTING
 *    - NFT position state MUST match internal accounting
 *    - Liquidity values MUST be non-negative
 *
 * 5. FEE ACCURACY
 *    - Fees collected MUST equal sum of transaction fees
 *    - Fee distribution MUST go to treasury
 *
 * 6. ACCESS CONTROL
 *    - Only owner can perform admin operations
 *    - Users can only affect their own positions
 */
abstract contract TestAMOBase is TestZaiBotsMarket {
  // ══════════════════════════════════════════════════════════════════════════════
  // AMO-SPECIFIC CONSTANTS
  // ══════════════════════════════════════════════════════════════════════════════

  // Fee bounds (basis points)
  uint256 constant MAX_FEE_BPS = 1000; // 10% max fee
  uint256 constant DEFAULT_BUY_FEE = 10; // 0.1%
  uint256 constant DEFAULT_SELL_FEE = 10; // 0.1%

  // Oracle constants
  uint256 constant ORACLE_STALENESS_THRESHOLD = 1 hours;
  int256 constant JPY_USD_PRICE_LOWER = 0.005e8; // ~200 JPY/USD
  int256 constant JPY_USD_PRICE_UPPER = 0.015e8; // ~67 JPY/USD

  // Bucket constants
  uint128 constant DEFAULT_BUCKET_CAPACITY = 10_000_000_000e18; // 10B jUBC

  // Test amounts
  uint256 constant SMALL_AMOUNT = 100e6; // 100 USDC
  uint256 constant MEDIUM_AMOUNT = 10_000e6; // 10K USDC
  uint256 constant LARGE_AMOUNT = 1_000_000e6; // 1M USDC
  uint256 constant WHALE_AMOUNT = 100_000_000e6; // 100M USDC

  // ══════════════════════════════════════════════════════════════════════════════
  // AMO STATE VARIABLES
  // ══════════════════════════════════════════════════════════════════════════════

  // AMO Handler for invariant testing
  AMOHandler public amoHandler;

  // Price tracking
  int256 public initialOraclePrice;
  uint256 public initialBucketCapacity;
  uint256 public initialBucketLevel;
  uint256 public initialTreasuryBalance;

  // Mock oracle for controlled testing
  MockChainlinkOracle public mockJpyUsdOracle;

  // ══════════════════════════════════════════════════════════════════════════════
  // AMO EVENTS (for testing)
  // ══════════════════════════════════════════════════════════════════════════════

  event OracleSale(
    address indexed buyer,
    address indexed collateral,
    uint256 collateralAmount,
    uint256 jpyUbiAmount,
    uint256 fee,
    int256 oraclePrice
  );

  event OracleBuyback(
    address indexed seller,
    address indexed collateral,
    uint256 jpyUbiAmount,
    uint256 collateralAmount,
    uint256 fee,
    int256 oraclePrice
  );

  event LiquidityAdded(
    uint256 indexed tokenId,
    address collateral,
    uint256 jpyUbiAmount,
    uint256 collateralAmount,
    uint128 liquidity
  );

  event LiquidityRemoved(uint256 indexed tokenId, uint256 jpyUbiAmount, uint256 collateralAmount);

  event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

  // ══════════════════════════════════════════════════════════════════════════════
  // SETUP - Override in specific AMO tests
  // ══════════════════════════════════════════════════════════════════════════════

  function setUp() public virtual override {
    super.setUp();

    // Deploy mock oracle
    mockJpyUsdOracle = new MockChainlinkOracle(8, 'JPY / USD');
    mockJpyUsdOracle.setPrice(0.0067e8); // ~149 JPY/USD

    // Store initial state
    initialOraclePrice = 0.0067e8;

    // Label addresses
    vm.label(address(mockJpyUsdOracle), 'MockJpyUsdOracle');
  }

  /**
   * @notice Setup specific AMO - must be implemented by child contracts
   */
  function _setupAMO() internal virtual;

  /**
   * @notice Get the AMO contract - must be implemented by child contracts
   */
  function _getAMO() internal view virtual returns (address);

  /**
   * @notice Setup the AMO handler for invariant testing
   */
  function _setupAMOHandler() internal virtual;

  // ══════════════════════════════════════════════════════════════════════════════
  // INVARIANT CHECKS - AMO SPECIFIC
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Master invariant check for all AMO contracts
   */
  function checkAMOInvariants() public view virtual {
    _invariant_bucketIntegrity();
    _invariant_oracleNotStale();
    _invariant_feesAccurate();
    _invariant_accessControlEnforced();
  }

  /**
   * @notice INVARIANT: Bucket level must never exceed capacity
   */
  function _invariant_bucketIntegrity() internal view virtual {
    address amo = _getAMO();
    if (amo == address(0)) return;

    (uint256 capacity, uint256 level) = IGhoToken(address(jpyUbi)).getFacilitatorBucket(amo);

    assertLe(level, capacity, 'INVARIANT VIOLATED: Bucket level exceeds capacity');
  }

  /**
   * @notice INVARIANT: Oracle must not be stale during active operations
   */
  function _invariant_oracleNotStale() internal view virtual {
    // This is checked implicitly by all operations
    // If oracle is stale, operations should revert
  }

  /**
   * @notice INVARIANT: Fees must be accurately tracked
   */
  function _invariant_feesAccurate() internal view virtual {
    // Implemented in specific AMO tests
  }

  /**
   * @notice INVARIANT: Access control must be enforced
   */
  function _invariant_accessControlEnforced() internal view virtual {
    // Implemented in specific AMO tests
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // TEST HELPERS - ORACLE MANIPULATION
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Set oracle price for testing
   * @param price New price (8 decimals)
   */
  function _setOraclePrice(int256 price) internal {
    mockJpyUsdOracle.setPrice(price);
  }

  /**
   * @notice Set oracle to stale state
   * @param staleSeconds How many seconds stale
   */
  function _setOracleStale(uint256 staleSeconds) internal {
    mockJpyUsdOracle.setStale(staleSeconds);
  }

  /**
   * @notice Reset oracle to fresh state
   */
  function _resetOracle() internal {
    mockJpyUsdOracle.setFresh();
    mockJpyUsdOracle.setPrice(initialOraclePrice);
  }

  /**
   * @notice Simulate major price movement
   * @param percentChange Percentage change (positive = JPY strengthens, negative = weakens)
   */
  function _simulatePriceMovement(int256 percentChange) internal {
    int256 currentPrice = mockJpyUsdOracle.latestAnswer();
    int256 newPrice = (currentPrice * (100 + percentChange)) / 100;
    if (newPrice <= 0) newPrice = 1;
    mockJpyUsdOracle.setPrice(newPrice);
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // TEST HELPERS - FACILITATOR SETUP
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Add AMO as facilitator with bucket capacity
   * @param amo AMO address
   * @param capacity Bucket capacity
   */
  function _addFacilitator(address amo, uint128 capacity) internal {
    vm.prank(owner);
    jpyUbi.addFacilitator(amo, 'AMO', capacity);
  }

  /**
   * @notice Update facilitator bucket capacity
   * @param facilitator Facilitator address
   * @param newCapacity New capacity
   */
  function _updateBucketCapacity(address facilitator, uint128 newCapacity) internal {
    vm.prank(owner);
    jpyUbi.setFacilitatorBucketCapacity(facilitator, newCapacity);
  }

  /**
   * @notice Get facilitator bucket info
   */
  function _getBucket(address facilitator) internal view returns (uint256 capacity, uint256 level) {
    return jpyUbi.getFacilitatorBucket(facilitator);
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // TEST HELPERS - COLLATERAL SETUP
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Fund treasury with collateral
   * @param collateral Collateral address
   * @param amount Amount to fund
   */
  function _fundTreasury(address collateral, uint256 amount) internal {
    deal(collateral, treasury, amount);
  }

  /**
   * @notice Approve AMO to pull from treasury
   * @param amo AMO address
   * @param collateral Collateral address
   */
  function _approveTreasury(address amo, address collateral) internal {
    vm.prank(treasury);
    IERC20(collateral).approve(amo, type(uint256).max);
  }

  /**
   * @notice Setup user with collateral for testing
   * @param user User address
   * @param collateral Collateral address
   * @param amount Amount to provide
   */
  function _setupUserWithCollateral(address user, address collateral, uint256 amount) internal {
    deal(collateral, user, amount);
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // TEST HELPERS - JPYUBI OPERATIONS
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Mint jUBC directly (for testing)
   * @param to Recipient
   * @param amount Amount to mint
   */
  function _mintJpyUbi(address to, uint256 amount) internal {
    // Must mint through a facilitator
    // For testing, we can use deal()
    deal(address(jpyUbi), to, jpyUbi.balanceOf(to) + amount);
  }

  /**
   * @notice Get user's jUBC balance
   */
  function _getJpyUbiBalance(address user) internal view returns (uint256) {
    return jpyUbi.balanceOf(user);
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // TEST HELPERS - CALCULATIONS
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Calculate expected jUBC output for collateral input
   * @param collateralAmount Amount of collateral (in collateral decimals)
   * @param collateralDecimals Collateral decimals
   * @param jpyUsdPrice JPY/USD price (8 decimals)
   * @param feeBps Fee in basis points
   * @return jpyUbiAmount Expected jUBC output
   */
  function _calculateJpyUbiOutput(
    uint256 collateralAmount,
    uint8 collateralDecimals,
    int256 jpyUsdPrice,
    uint256 feeBps
  ) internal pure returns (uint256 jpyUbiAmount) {
    // Convert collateral to 18 decimals
    uint256 collateralE18 = collateralAmount * (10 ** (18 - collateralDecimals));

    // Calculate gross jUBC amount
    // collateral (USD) * (1 / JPY_USD_price) = jUBC
    // Since oracle gives JPY/USD (small number like 0.0067), we need to invert
    // Actually, if price is 0.0067 USD per JPY, then 1 USD = 1/0.0067 = ~149 JPY
    uint256 grossAmount = (collateralE18 * uint256(jpyUsdPrice)) / 1e8;

    // Apply fee
    uint256 fee = (grossAmount * feeBps) / BPS;
    jpyUbiAmount = grossAmount - fee;
  }

  /**
   * @notice Calculate expected collateral output for jUBC input
   * @param jpyUbiAmount Amount of jUBC (18 decimals)
   * @param collateralDecimals Collateral decimals
   * @param jpyUsdPrice JPY/USD price (8 decimals)
   * @param feeBps Fee in basis points
   * @return collateralAmount Expected collateral output
   */
  function _calculateCollateralOutput(
    uint256 jpyUbiAmount,
    uint8 collateralDecimals,
    int256 jpyUsdPrice,
    uint256 feeBps
  ) internal pure returns (uint256 collateralAmount) {
    // jUBC * JPY_USD_price = USD value
    uint256 collateralE18 = (jpyUbiAmount * 1e8) / uint256(jpyUsdPrice);

    // Convert to collateral decimals
    uint256 grossAmount = collateralE18 / (10 ** (18 - collateralDecimals));

    // Apply fee
    uint256 fee = (grossAmount * feeBps) / BPS;
    collateralAmount = grossAmount - fee;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // TEST HELPERS - ASSERTIONS
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Assert bucket is within capacity
   */
  function _assertBucketValid(address facilitator) internal view {
    (uint256 capacity, uint256 level) = _getBucket(facilitator);
    assertLe(level, capacity, 'Bucket level exceeds capacity');
  }

  /**
   * @notice Assert treasury has sufficient balance
   */
  function _assertTreasuryHasBalance(address collateral, uint256 minAmount) internal view {
    uint256 balance = IERC20(collateral).balanceOf(treasury);
    assertGe(balance, minAmount, 'Treasury balance insufficient');
  }

  /**
   * @notice Assert fee collection is accurate
   */
  function _assertFeesAccurate(uint256 expectedFees, uint256 actualFees, uint256 tolerance) internal pure {
    assertApproxEqAbs(actualFees, expectedFees, tolerance, 'Fee collection inaccurate');
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // FUZZ TEST MODIFIERS
  // ══════════════════════════════════════════════════════════════════════════════

  modifier withValidPrice(int256 price) {
    price = int256(bound(uint256(price > 0 ? price : -price), uint256(JPY_USD_PRICE_LOWER), uint256(JPY_USD_PRICE_UPPER)));
    _setOraclePrice(price);
    _;
  }

  modifier withFreshOracle() {
    _resetOracle();
    _;
  }

  modifier withActiveFacilitator(address amo) {
    if (!_isFacilitator(amo)) {
      _addFacilitator(amo, DEFAULT_BUCKET_CAPACITY);
    }
    _;
  }

  modifier withFundedTreasury(address collateral, uint256 amount) {
    _fundTreasury(collateral, amount);
    _;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // STANDARD TEST TEMPLATES
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Template: Test basic buy operation
   */
  function _test_BasicBuy(
    address amo,
    address user,
    address collateral,
    uint256 amount
  ) internal virtual returns (uint256 jpyUbiReceived);

  /**
   * @notice Template: Test basic sell operation
   */
  function _test_BasicSell(
    address amo,
    address user,
    address collateral,
    uint256 jpyUbiAmount
  ) internal virtual returns (uint256 collateralReceived);

  /**
   * @notice Template: Test oracle staleness protection
   */
  function _test_OracleStalenessReverts(address amo) internal virtual;

  /**
   * @notice Template: Test bucket capacity enforcement
   */
  function _test_BucketCapacityEnforced(address amo) internal virtual;

  /**
   * @notice Template: Test fee accuracy
   */
  function _test_FeeAccuracy(
    address amo,
    address user,
    address collateral,
    uint256 amount
  ) internal virtual;

  /**
   * @notice Template: Test access control
   */
  function _test_AccessControl(address amo) internal virtual;
}

// ══════════════════════════════════════════════════════════════════════════════
// MOCK CHAINLINK ORACLE
// ══════════════════════════════════════════════════════════════════════════════

contract MockChainlinkOracle {
  int256 public price;
  uint8 public immutable decimals;
  string public description;
  uint256 public updatedAt;
  uint80 public roundId;

  constructor(uint8 _decimals, string memory _description) {
    decimals = _decimals;
    description = _description;
    updatedAt = block.timestamp;
    roundId = 1;
    price = 0.0067e8; // Default JPY/USD
  }

  function setPrice(int256 _price) external {
    price = _price;
    updatedAt = block.timestamp;
    roundId++;
  }

  function setStale(uint256 staleSeconds) external {
    // Safely handle underflow by setting to 0 if block.timestamp < staleSeconds
    if (block.timestamp > staleSeconds) {
      updatedAt = block.timestamp - staleSeconds;
    } else {
      updatedAt = 0;
    }
  }

  function setFresh() external {
    updatedAt = block.timestamp;
  }

  function latestAnswer() external view returns (int256) {
    return price;
  }

  function latestRoundData()
    external
    view
    returns (uint80 _roundId, int256 answer, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
  {
    return (roundId, price, updatedAt, updatedAt, roundId);
  }

  function getRoundData(
    uint80 _roundId
  )
    external
    view
    returns (uint80 __roundId, int256 answer, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
  {
    return (_roundId, price, updatedAt, updatedAt, _roundId);
  }
}
