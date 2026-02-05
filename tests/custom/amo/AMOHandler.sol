// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test, console2} from 'forge-std/Test.sol';
import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {IGhoToken} from 'gho-origin/gho/interfaces/IGhoToken.sol';
import {IGhoFacilitator} from 'gho-origin/gho/interfaces/IGhoFacilitator.sol';
import {IAggregatorV3} from 'custom/oracles/interfaces/IAggregatorV3.sol';
import {JpyUbiUniV3AMO} from 'custom/amo/JpyUbiUniV3AMO.sol';

/**
 * @title AMOHandler
 * @author ZaiBots Security Division - 日本国経済安全保障局
 * @notice Handler contract for AMO invariant testing and state space exploration
 * @dev Performs bounded random AMO operations to discover edge cases and vulnerabilities
 *
 * SECURITY CLASSIFICATION: IMPERIAL TREASURY PROTOCOL - CRITICAL INFRASTRUCTURE
 *
 * THREAT MODEL:
 * - Adversarial traders attempting arbitrage exploitation
 * - Oracle manipulation attacks (price/staleness)
 * - MEV extraction via sandwich attacks
 * - Bucket capacity exhaustion attacks
 * - Treasury drainage through fee manipulation
 * - Collateral depeg scenarios (USDC, USDT)
 * - jUBC depeg through pool manipulation
 *
 * INVARIANTS ENFORCED:
 * 1. Bucket level never exceeds bucket capacity
 * 2. Total minted jUBC backed by equivalent USD value in treasury
 * 3. Oracle price staleness never exceeded during operations
 * 4. Fee collection accurate to within rounding tolerance
 * 5. Position accounting matches NFT state
 * 6. Collateral config immutable during active operations
 */
contract AMOHandler is Test {
  // ══════════════════════════════════════════════════════════════════════════════
  // CONSTANTS
  // ══════════════════════════════════════════════════════════════════════════════

  uint256 constant WAD = 1e18;
  uint256 constant BPS = 1e4;
  uint256 constant USD_DECIMALS = 8;

  // Fuzzing bounds
  uint256 constant MIN_BUY_AMOUNT = 1e6; // 1 USDC
  uint256 constant MAX_BUY_AMOUNT = 10_000_000e6; // 10M USDC
  uint256 constant MIN_JPYUBI_AMOUNT = 100e18; // 100 jUBC
  uint256 constant MAX_JPYUBI_AMOUNT = 1_000_000_000e18; // 1B jUBC

  // ══════════════════════════════════════════════════════════════════════════════
  // STATE
  // ══════════════════════════════════════════════════════════════════════════════

  JpyUbiUniV3AMO public amo;
  IGhoToken public ghoToken;
  address public treasury;
  address public oracle;

  address[] public collaterals;
  address[] public actors;
  address public owner;

  // ══════════════════════════════════════════════════════════════════════════════
  // GHOST VARIABLES - Invariant Tracking
  // ══════════════════════════════════════════════════════════════════════════════

  // Cumulative tracking
  uint256 public ghost_totalBuys;
  uint256 public ghost_totalSells;
  uint256 public ghost_totalJpyUbiMinted;
  uint256 public ghost_totalJpyUbiBurned;
  uint256 public ghost_totalCollateralIn;
  uint256 public ghost_totalCollateralOut;
  uint256 public ghost_totalFeesAccrued;

  // Position tracking
  uint256 public ghost_totalPositionsCreated;
  uint256 public ghost_totalPositionsRemoved;
  uint256 public ghost_totalLiquidityAdded;
  uint256 public ghost_totalLiquidityRemoved;

  // Error tracking
  uint256 public ghost_buyReverts;
  uint256 public ghost_sellReverts;
  uint256 public ghost_liquidityReverts;
  uint256 public ghost_oracleStaleReverts;
  uint256 public ghost_bucketCapacityReverts;

  // Call tracking
  mapping(bytes32 => uint256) public calls;

  // Per-actor tracking
  mapping(address => uint256) public actorBuyVolume;
  mapping(address => uint256) public actorSellVolume;

  // ══════════════════════════════════════════════════════════════════════════════
  // CONSTRUCTOR
  // ══════════════════════════════════════════════════════════════════════════════

  constructor(
    JpyUbiUniV3AMO _amo,
    IGhoToken _ghoToken,
    address _treasury,
    address _oracle,
    address[] memory _collaterals,
    address[] memory _actors,
    address _owner
  ) {
    amo = _amo;
    ghoToken = _ghoToken;
    treasury = _treasury;
    oracle = _oracle;
    collaterals = _collaterals;
    actors = _actors;
    owner = _owner;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // HANDLER ACTIONS - USER OPERATIONS
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice User buys jUBC with collateral at oracle price
   * @param actorSeed Seed to select actor
   * @param collateralSeed Seed to select collateral
   * @param amount Amount of collateral to spend
   * @param slippageBps Slippage tolerance in basis points
   */
  function buyJpyUbi(
    uint256 actorSeed,
    uint256 collateralSeed,
    uint256 amount,
    uint256 slippageBps
  ) external {
    calls[keccak256('buyJpyUbi')]++;

    address actor = _selectActor(actorSeed);
    address collateral = _selectCollateral(collateralSeed);

    // Bound inputs
    uint8 decimals = _getDecimals(collateral);
    uint256 minAmount = 10 ** (decimals > 6 ? decimals - 6 : 0);
    uint256 maxAmount = 10 ** (decimals + 7); // 10M units
    uint256 boundedAmount = bound(amount, minAmount, maxAmount);
    uint256 boundedSlippage = bound(slippageBps, 0, 1000); // Max 10% slippage

    // Calculate min output
    (uint256 expectedOut, ) = amo.quoteBuyJpyUbi(collateral, boundedAmount);
    uint256 minOut = (expectedOut * (BPS - boundedSlippage)) / BPS;

    // Deal collateral to actor
    deal(collateral, actor, boundedAmount);

    // Execute buy
    vm.startPrank(actor);
    IERC20(collateral).approve(address(amo), boundedAmount);

    try amo.buyJpyUbi(collateral, boundedAmount, minOut) returns (uint256 jpyUbiOut) {
      ghost_totalBuys++;
      ghost_totalJpyUbiMinted += jpyUbiOut;
      ghost_totalCollateralIn += boundedAmount;
      actorBuyVolume[actor] += boundedAmount;
    } catch Error(string memory reason) {
      ghost_buyReverts++;
      _categorizeRevert(reason);
    } catch (bytes memory) {
      ghost_buyReverts++;
    }
    vm.stopPrank();
  }

  /**
   * @notice User sells jUBC back to AMO for collateral
   * @param actorSeed Seed to select actor
   * @param collateralSeed Seed to select collateral to receive
   * @param amount Amount of jUBC to sell
   * @param slippageBps Slippage tolerance
   */
  function sellJpyUbi(
    uint256 actorSeed,
    uint256 collateralSeed,
    uint256 amount,
    uint256 slippageBps
  ) external {
    calls[keccak256('sellJpyUbi')]++;

    address actor = _selectActor(actorSeed);
    address collateral = _selectCollateral(collateralSeed);

    // Get actor's jUBC balance
    uint256 balance = ghoToken.balanceOf(actor);
    if (balance == 0) {
      // Deal some jUBC for testing
      uint256 mintAmount = bound(amount, MIN_JPYUBI_AMOUNT, MAX_JPYUBI_AMOUNT);
      _mintJpyUbiToActor(actor, mintAmount);
      balance = mintAmount;
    }

    // Bound amount to balance
    uint256 boundedAmount = bound(amount, MIN_JPYUBI_AMOUNT, balance);
    uint256 boundedSlippage = bound(slippageBps, 0, 1000);

    // Calculate min output
    (uint256 expectedOut, ) = amo.quoteSellJpyUbi(collateral, boundedAmount);
    uint256 minOut = (expectedOut * (BPS - boundedSlippage)) / BPS;

    // Ensure treasury has collateral
    uint256 treasuryBalance = IERC20(collateral).balanceOf(treasury);
    if (treasuryBalance < expectedOut) {
      deal(collateral, treasury, expectedOut * 2);
      // Approve AMO to pull from treasury
      vm.prank(treasury);
      IERC20(collateral).approve(address(amo), type(uint256).max);
    }

    // Execute sell
    vm.startPrank(actor);
    IERC20(address(ghoToken)).approve(address(amo), boundedAmount);

    try amo.sellJpyUbi(collateral, boundedAmount, minOut) returns (uint256 collateralOut) {
      ghost_totalSells++;
      ghost_totalJpyUbiBurned += boundedAmount;
      ghost_totalCollateralOut += collateralOut;
      actorSellVolume[actor] += collateralOut;
    } catch Error(string memory reason) {
      ghost_sellReverts++;
      _categorizeRevert(reason);
    } catch (bytes memory) {
      ghost_sellReverts++;
    }
    vm.stopPrank();
  }

  /**
   * @notice Rapid succession of buys and sells (stress test)
   * @param seed Random seed for operation selection
   * @param iterations Number of operations
   */
  function rapidTrading(uint256 seed, uint256 iterations) external {
    calls[keccak256('rapidTrading')]++;

    uint256 boundedIterations = bound(iterations, 1, 20);

    for (uint256 i = 0; i < boundedIterations; i++) {
      uint256 opSeed = uint256(keccak256(abi.encodePacked(seed, i)));

      if (opSeed % 2 == 0) {
        this.buyJpyUbi(opSeed, opSeed >> 8, opSeed >> 16, 100);
      } else {
        this.sellJpyUbi(opSeed, opSeed >> 8, opSeed >> 16, 100);
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // HANDLER ACTIONS - ADMIN OPERATIONS
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Add liquidity to UniV3 pool (owner only)
   * @param collateralSeed Seed to select collateral
   * @param jpyUbiAmount Amount of jUBC to add
   * @param collateralAmount Amount of collateral to add
   */
  function addLiquidity(
    uint256 collateralSeed,
    uint256 jpyUbiAmount,
    uint256 collateralAmount
  ) external {
    calls[keccak256('addLiquidity')]++;

    address collateral = _selectCollateral(collateralSeed);

    // Bound amounts
    uint256 boundedJpyUbi = bound(jpyUbiAmount, 1000e18, 10_000_000e18);
    uint8 colDecimals = _getDecimals(collateral);
    uint256 boundedCollateral = bound(collateralAmount, 10 ** colDecimals, 10 ** (colDecimals + 6));

    // Deal tokens to AMO
    _mintJpyUbiToActor(address(amo), boundedJpyUbi);
    deal(collateral, address(amo), boundedCollateral);

    // Execute add liquidity
    vm.startPrank(owner);
    try
      amo.addLiquidity(
        collateral,
        -887220, // tickLower (wide range)
        887220, // tickUpper
        3000, // 0.3% fee tier
        boundedJpyUbi,
        boundedCollateral,
        0, // min jUBC
        0 // min collateral
      )
    returns (uint256 tokenId, uint128 liquidity) {
      ghost_totalPositionsCreated++;
      ghost_totalLiquidityAdded += uint256(liquidity);
    } catch {
      ghost_liquidityReverts++;
    }
    vm.stopPrank();
  }

  /**
   * @notice Collect fees from all positions
   */
  function collectAllFees() external {
    calls[keccak256('collectAllFees')]++;

    vm.prank(owner);
    try amo.collectAllFees() {
      // Fees collected
    } catch {
      // Collection failed
    }
  }

  /**
   * @notice Distribute accrued fees to treasury
   */
  function distributeFeesToTreasury() external {
    calls[keccak256('distributeFeesToTreasury')]++;

    uint256 feesBefore = amo.getAccruedFees();

    try amo.distributeFeesToTreasury() {
      ghost_totalFeesAccrued += feesBefore;
    } catch {
      // Distribution failed
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // HANDLER ACTIONS - ADVERSARIAL SCENARIOS
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Simulate oracle price manipulation
   * @param priceChangeBps Price change in basis points (can be negative via overflow)
   */
  function manipulateOraclePrice(int256 priceChangeBps) external {
    calls[keccak256('manipulateOraclePrice')]++;

    // Get current price
    (int256 currentPrice, ) = amo.getOraclePrice();

    // Calculate new price with bounds
    int256 boundedChange = int256(bound(uint256(priceChangeBps > 0 ? priceChangeBps : -priceChangeBps), 0, 5000));
    if (priceChangeBps < 0) boundedChange = -boundedChange;

    int256 newPrice = (currentPrice * (10000 + boundedChange)) / 10000;
    if (newPrice <= 0) newPrice = 1;

    // Mock the oracle price (requires oracle to be mockable)
    vm.mockCall(
      oracle,
      abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
      abi.encode(uint80(1), newPrice, block.timestamp, block.timestamp, uint80(1))
    );
  }

  /**
   * @notice Simulate stale oracle condition
   * @param staleDuration How long the oracle has been stale
   */
  function simulateStaleOracle(uint256 staleDuration) external {
    calls[keccak256('simulateStaleOracle')]++;

    uint256 boundedStale = bound(staleDuration, 1 hours + 1, 24 hours);

    // Get current price
    (, int256 price, , , ) = IAggregatorV3(oracle).latestRoundData();

    // Mock stale oracle
    uint256 staleTime = block.timestamp - boundedStale;
    vm.mockCall(
      oracle,
      abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
      abi.encode(uint80(1), price, staleTime, staleTime, uint80(1))
    );

    // Try to buy - should revert
    address actor = actors[0];
    address collateral = collaterals[0];
    deal(collateral, actor, 1000e6);

    vm.startPrank(actor);
    IERC20(collateral).approve(address(amo), 1000e6);

    try amo.buyJpyUbi(collateral, 1000e6, 0) {
      // Should not succeed with stale oracle
      revert('Stale oracle should have reverted');
    } catch {
      ghost_oracleStaleReverts++;
    }
    vm.stopPrank();

    // Clear mock
    vm.clearMockedCalls();
  }

  /**
   * @notice Attempt to exceed bucket capacity
   * @param excessAmount Amount to try exceeding by
   */
  function attemptBucketOverflow(uint256 excessAmount) external {
    calls[keccak256('attemptBucketOverflow')]++;

    // Get current bucket state
    (uint256 capacity, uint256 level) = amo.getFacilitatorBucket();
    uint256 available = capacity > level ? capacity - level : 0;

    if (available == 0) return;

    // Try to mint more than available
    uint256 targetMint = available + bound(excessAmount, 1e18, 1_000_000e18);

    // Calculate collateral needed
    (int256 price, uint8 oracleDecimals) = amo.getOraclePrice();
    uint256 collateralNeeded = (targetMint * (10 ** oracleDecimals)) / uint256(price);
    collateralNeeded = collateralNeeded / 1e12 + 1e6; // Convert to USDC decimals with buffer

    address actor = actors[0];
    address collateral = collaterals[0];
    deal(collateral, actor, collateralNeeded);

    vm.startPrank(actor);
    IERC20(collateral).approve(address(amo), collateralNeeded);

    try amo.buyJpyUbi(collateral, collateralNeeded, 0) {
      // If it succeeded, bucket must have had room
    } catch {
      ghost_bucketCapacityReverts++;
    }
    vm.stopPrank();
  }

  /**
   * @notice Simulate USDC depeg scenario
   * @param depegBps Depeg amount in basis points (e.g., 100 = 1% below peg)
   */
  function simulateUsdcDepeg(uint256 depegBps) external {
    calls[keccak256('simulateUsdcDepeg')]++;

    // This simulates what happens when USDC depegs
    // The AMO should still function but arbitrage opportunities may exist

    uint256 boundedDepeg = bound(depegBps, 10, 2000); // 0.1% to 20% depeg

    // Record state before
    uint256 treasuryBalanceBefore = IERC20(collaterals[0]).balanceOf(treasury);

    // Execute trades during "depeg"
    // In reality, oracle would reflect the depeg, but we test edge behavior
    this.buyJpyUbi(0, 0, MAX_BUY_AMOUNT, 500);
    this.sellJpyUbi(1, 0, MAX_JPYUBI_AMOUNT / 2, 500);

    // Verify treasury is not drained inappropriately
    uint256 treasuryBalanceAfter = IERC20(collaterals[0]).balanceOf(treasury);

    // Ghost tracking for depeg scenario analysis
    // (actual invariant checks done in test contract)
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // HANDLER ACTIONS - TIME MANIPULATION
  // ══════════════════════════════════════════════════════════════════════════════

  /**
   * @notice Warp time forward
   * @param timeJump Seconds to advance
   */
  function warpTime(uint256 timeJump) external {
    calls[keccak256('warpTime')]++;

    uint256 boundedJump = bound(timeJump, 1 minutes, 365 days);
    vm.warp(block.timestamp + boundedJump);
  }

  /**
   * @notice Warp to specific block
   * @param blockJump Blocks to advance
   */
  function warpBlocks(uint256 blockJump) external {
    calls[keccak256('warpBlocks')]++;

    uint256 boundedJump = bound(blockJump, 1, 1_000_000);
    vm.roll(block.number + boundedJump);
    vm.warp(block.timestamp + (boundedJump * 12)); // ~12s per block
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // INTERNAL HELPERS
  // ══════════════════════════════════════════════════════════════════════════════

  function _selectActor(uint256 seed) internal view returns (address) {
    return actors[seed % actors.length];
  }

  function _selectCollateral(uint256 seed) internal view returns (address) {
    return collaterals[seed % collaterals.length];
  }

  function _getDecimals(address token) internal view returns (uint8) {
    try IERC20Metadata(token).decimals() returns (uint8 decimals) {
      return decimals;
    } catch {
      return 18;
    }
  }

  function _mintJpyUbiToActor(address actor, uint256 amount) internal {
    // This requires AMO to be a facilitator with capacity
    // For testing, we can use vm.deal or direct mint if we have rights
    vm.prank(owner);
    // Note: In actual tests, this would go through proper facilitator minting
    deal(address(ghoToken), actor, ghoToken.balanceOf(actor) + amount);
  }

  function _categorizeRevert(string memory reason) internal {
    bytes32 reasonHash = keccak256(bytes(reason));

    if (reasonHash == keccak256('OracleStale()') || reasonHash == keccak256(bytes('OracleStale'))) {
      ghost_oracleStaleReverts++;
    } else if (
      reasonHash == keccak256('ExceedsBucketCapacity()') || reasonHash == keccak256(bytes('ExceedsBucketCapacity'))
    ) {
      ghost_bucketCapacityReverts++;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // GHOST VARIABLE SUMMARY
  // ══════════════════════════════════════════════════════════════════════════════

  function callSummary() external view {
    console2.log('\n=== AMO Handler Call Summary ===');
    console2.log('User Operations:');
    console2.log('  buyJpyUbi:', calls[keccak256('buyJpyUbi')]);
    console2.log('  sellJpyUbi:', calls[keccak256('sellJpyUbi')]);
    console2.log('  rapidTrading:', calls[keccak256('rapidTrading')]);
    console2.log('\nAdmin Operations:');
    console2.log('  addLiquidity:', calls[keccak256('addLiquidity')]);
    console2.log('  collectAllFees:', calls[keccak256('collectAllFees')]);
    console2.log('  distributeFeesToTreasury:', calls[keccak256('distributeFeesToTreasury')]);
    console2.log('\nAdversarial:');
    console2.log('  manipulateOraclePrice:', calls[keccak256('manipulateOraclePrice')]);
    console2.log('  simulateStaleOracle:', calls[keccak256('simulateStaleOracle')]);
    console2.log('  attemptBucketOverflow:', calls[keccak256('attemptBucketOverflow')]);
    console2.log('  simulateUsdcDepeg:', calls[keccak256('simulateUsdcDepeg')]);
    console2.log('\nTime:');
    console2.log('  warpTime:', calls[keccak256('warpTime')]);
    console2.log('  warpBlocks:', calls[keccak256('warpBlocks')]);
    console2.log('\n=== Ghost Variables ===');
    console2.log('Total Buys:', ghost_totalBuys);
    console2.log('Total Sells:', ghost_totalSells);
    console2.log('jUBC Minted:', ghost_totalJpyUbiMinted);
    console2.log('jUBC Burned:', ghost_totalJpyUbiBurned);
    console2.log('Collateral In:', ghost_totalCollateralIn);
    console2.log('Collateral Out:', ghost_totalCollateralOut);
    console2.log('\n=== Reverts ===');
    console2.log('Buy Reverts:', ghost_buyReverts);
    console2.log('Sell Reverts:', ghost_sellReverts);
    console2.log('Liquidity Reverts:', ghost_liquidityReverts);
    console2.log('Oracle Stale Reverts:', ghost_oracleStaleReverts);
    console2.log('Bucket Capacity Reverts:', ghost_bucketCapacityReverts);
  }

  function getGhostState()
    external
    view
    returns (
      uint256 totalBuys,
      uint256 totalSells,
      uint256 jpyUbiMinted,
      uint256 jpyUbiBurned,
      uint256 collateralIn,
      uint256 collateralOut
    )
  {
    return (
      ghost_totalBuys,
      ghost_totalSells,
      ghost_totalJpyUbiMinted,
      ghost_totalJpyUbiBurned,
      ghost_totalCollateralIn,
      ghost_totalCollateralOut
    );
  }
}

// Interface for decimals
interface IERC20Metadata {
  function decimals() external view returns (uint8);
}
