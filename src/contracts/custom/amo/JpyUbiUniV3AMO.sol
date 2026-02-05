// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from 'openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol';
import {IAggregatorV3} from 'custom/oracles/interfaces/IAggregatorV3.sol';
import {IGhoToken} from 'gho-origin/gho/interfaces/IGhoToken.sol';
import {IGhoFacilitator} from 'gho-origin/gho/interfaces/IGhoFacilitator.sol';
import {
  IUniswapV3Factory,
  IUniswapV3Pool,
  INonfungiblePositionManager,
  ISwapRouter
} from './interfaces/IUniswapV3.sol';

/**
 * @title JpyUbiUniV3AMO
 * @notice UniswapV3 AMO for jUBC (JPY-denominated UBI stablecoin)
 * @dev Key features:
 *      1. Oracle-based minting: Mint jUBC to users at Chainlink JPY/USD price
 *      2. UniV3 liquidity management: Provide liquidity to Uni V3 pools
 *      3. Treasury management: USD backing goes to treasury for yield farming
 *
 * Implements IGhoFacilitator to integrate with the GHO token system.
 * Uses the facilitator's bucket capacity/level from GhoToken instead of custom tracking.
 *
 * The main innovation is the oracle-based selling mechanism:
 * - Users pay in USD stablecoins (USDC, USDT, etc.)
 * - AMO mints jUBC at the current Chainlink JPY/USD oracle price
 * - Treasury receives the USD backing directly (not into LP)
 * - This prevents arbitrage and ensures 1:1 USD backing per jUBC value
 */
contract JpyUbiUniV3AMO is Ownable, ReentrancyGuard, IGhoFacilitator {
  using SafeERC20 for IERC20;

  // ============ Constants ============

  uint256 private constant PRICE_PRECISION = 1e18;
  uint256 private constant BPS_PRECISION = 10000;

  // ============ Structs ============

  /// @notice Collateral configuration - packed for gas efficiency (bool + uint8 = 2 bytes, fits in one slot)
  struct CollateralConfig {
    bool allowed;
    uint8 decimals;
  }

  // ============ State Variables ============

  // Core tokens
  IGhoToken public immutable GHO_TOKEN; // jUBC token (18 decimals)

  // Chainlink oracle for JPY/USD price
  IAggregatorV3 public jpyUsdOracle;
  uint256 public oracleStalenessThreshold = 1 hours;

  // Allowed collaterals for purchasing jUBC - packed struct for gas efficiency
  mapping(address => CollateralConfig) public collaterals;
  address[] public collateralList;

  // GHO Treasury where USD backing and fees are sent (implements IGhoFacilitator)
  address internal _ghoTreasury;

  // Fee settings (in basis points, e.g., 30 = 0.30%)
  uint256 public buyFee; // Fee when users buy jUBC
  uint256 public sellFee; // Fee when users sell jUBC back

  // Accrued fees in jUBC (for IGhoFacilitator)
  uint256 internal _accruedFees;

  // UniswapV3 infrastructure
  IUniswapV3Factory public univ3Factory;
  INonfungiblePositionManager public univ3Positions;
  ISwapRouter public univ3Router;

  // Position tracking
  struct Position {
    uint256 tokenId;
    address collateral;
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
    uint24 feeTier;
  }
  Position[] public positions;
  mapping(uint256 => uint256) public tokenIdToIndex; // tokenId -> positions array index

  // Pause states
  bool public oracleSalesPaused;
  bool public liquidityOpsPaused;

  // ============ Events ============

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

  event LiquidityRemoved(
    uint256 indexed tokenId,
    uint256 jpyUbiAmount,
    uint256 collateralAmount
  );

  event FeesCollected(
    uint256 indexed tokenId,
    uint256 amount0,
    uint256 amount1
  );

  event CollateralAdded(address indexed collateral, uint8 decimals);
  event CollateralRemoved(address indexed collateral);
  event OracleUpdated(address indexed oldOracle, address indexed newOracle);
  event FeesUpdated(uint256 buyFee, uint256 sellFee);

  // ============ Errors ============

  error ZeroAddress();
  error CollateralNotAllowed();
  error CollateralAlreadyAllowed();
  error OracleStale();
  error OracleInvalidPrice();
  error ExceedsBucketCapacity();
  error InsufficientOutput();
  error OracleSalesPaused();
  error LiquidityOpsPaused();
  error InvalidFee();
  error PositionNotFound();
  error InvalidAmount();

  // ============ Constructor ============

  constructor(
    address _ghoToken,
    address _jpyUsdOracle,
    address ghoTreasury_,
    address _univ3Factory,
    address _univ3Positions,
    address _univ3Router
  ) Ownable(msg.sender) {
    if (_ghoToken == address(0)) revert ZeroAddress();
    if (_jpyUsdOracle == address(0)) revert ZeroAddress();
    if (ghoTreasury_ == address(0)) revert ZeroAddress();

    GHO_TOKEN = IGhoToken(_ghoToken);
    jpyUsdOracle = IAggregatorV3(_jpyUsdOracle);
    _ghoTreasury = ghoTreasury_;

    // UniV3 addresses (can be zero if not using liquidity features)
    if (_univ3Factory != address(0)) {
      univ3Factory = IUniswapV3Factory(_univ3Factory);
      univ3Positions = INonfungiblePositionManager(_univ3Positions);
      univ3Router = ISwapRouter(_univ3Router);
    }

    // Default fees: 0.1% buy, 0.1% sell
    buyFee = 10;
    sellFee = 10;
  }

  // ============ Modifiers ============

  modifier whenOracleSalesNotPaused() {
    if (oracleSalesPaused) revert OracleSalesPaused();
    _;
  }

  modifier whenLiquidityOpsNotPaused() {
    if (liquidityOpsPaused) revert LiquidityOpsPaused();
    _;
  }

  // ============ IGhoFacilitator Implementation ============

  /// @inheritdoc IGhoFacilitator
  function distributeFeesToTreasury() external override {
    uint256 fees = _accruedFees;
    if (fees > 0) {
      _accruedFees = 0;
      IERC20(address(GHO_TOKEN)).safeTransfer(_ghoTreasury, fees);
      emit FeesDistributedToTreasury(_ghoTreasury, address(GHO_TOKEN), fees);
    }
  }

  /// @inheritdoc IGhoFacilitator
  function updateGhoTreasury(address newGhoTreasury) external override onlyOwner {
    if (newGhoTreasury == address(0)) revert ZeroAddress();
    address oldTreasury = _ghoTreasury;
    _ghoTreasury = newGhoTreasury;
    emit GhoTreasuryUpdated(oldTreasury, newGhoTreasury);
  }

  /// @inheritdoc IGhoFacilitator
  function getGhoTreasury() external view override returns (address) {
    return _ghoTreasury;
  }

  // ============ Oracle-Based Sales (Main Feature) ============

  /**
   * @notice Buy jUBC tokens at the current Chainlink oracle price
   * @dev User pays in allowed collateral (USD stablecoin), receives jUBC
   *      The collateral goes to treasury for yield farming
   *      Uses GhoToken's facilitator bucket for mint capacity
   * @param collateral The collateral token address (e.g., USDC)
   * @param collateralAmount Amount of collateral to spend
   * @param minJpyUbiOut Minimum jUBC to receive (slippage protection)
   * @return jpyUbiAmount Amount of jUBC minted to the buyer
   */
  function buyJpyUbi(
    address collateral,
    uint256 collateralAmount,
    uint256 minJpyUbiOut
  ) external nonReentrant whenOracleSalesNotPaused returns (uint256 jpyUbiAmount) {
    CollateralConfig memory config = collaterals[collateral];
    if (!config.allowed) revert CollateralNotAllowed();
    if (collateralAmount == 0) revert InvalidAmount();

    // Get oracle price (JPY per USD, 8 decimals typically)
    (int256 price, uint8 oracleDecimals) = _getOraclePrice();

    // Calculate jUBC amount
    // price = JPY/USD (e.g., 149.5 JPY per USD = 14950000000 with 8 decimals)
    // jpyUbiAmount = collateralAmount * price / 10^oracleDecimals
    // Adjust for collateral decimals vs jUBC decimals (18)
    uint8 colDecimals = config.decimals;

    // Convert collateral to 18 decimals, then multiply by JPY/USD price
    uint256 collateralE18 = collateralAmount * (10 ** (18 - colDecimals));
    uint256 grossAmount = (collateralE18 * uint256(price)) / (10 ** oracleDecimals);

    // Apply buy fee
    uint256 fee = (grossAmount * buyFee) / BPS_PRECISION;
    jpyUbiAmount = grossAmount - fee;

    if (jpyUbiAmount < minJpyUbiOut) revert InsufficientOutput();

    // Check facilitator bucket capacity (handled by GhoToken.mint, but we can check early)
    // Must include fee in capacity check since we mint both user amount and fee
    (uint256 bucketCapacity, uint256 bucketLevel) = GHO_TOKEN.getFacilitatorBucket(address(this));
    if (bucketLevel + grossAmount > bucketCapacity) revert ExceedsBucketCapacity();

    // Transfer collateral to treasury
    IERC20(collateral).safeTransferFrom(msg.sender, _ghoTreasury, collateralAmount);

    // Mint jUBC to buyer (GhoToken tracks bucket level automatically)
    GHO_TOKEN.mint(msg.sender, jpyUbiAmount);

    // Mint fee amount to this contract for later distribution to treasury
    if (fee > 0) {
      GHO_TOKEN.mint(address(this), fee);
      _accruedFees += fee;
    }

    emit OracleSale(msg.sender, collateral, collateralAmount, jpyUbiAmount, fee, price);
  }

  /**
   * @notice Sell jUBC back to the AMO at oracle price
   * @dev User returns jUBC, receives collateral from treasury
   *      Only works if treasury has sufficient collateral
   * @param collateral The collateral token to receive (e.g., USDC)
   * @param jpyUbiAmount Amount of jUBC to sell
   * @param minCollateralOut Minimum collateral to receive (slippage protection)
   * @return collateralAmount Amount of collateral sent to seller
   */
  function sellJpyUbi(
    address collateral,
    uint256 jpyUbiAmount,
    uint256 minCollateralOut
  ) external nonReentrant whenOracleSalesNotPaused returns (uint256 collateralAmount) {
    CollateralConfig memory config = collaterals[collateral];
    if (!config.allowed) revert CollateralNotAllowed();
    if (jpyUbiAmount == 0) revert InvalidAmount();

    // Get oracle price
    (int256 price, uint8 oracleDecimals) = _getOraclePrice();

    // Calculate collateral amount
    // collateralAmount = jpyUbiAmount / price * 10^oracleDecimals
    uint8 colDecimals = config.decimals;

    // jpyUbiAmount is in 18 decimals, price is JPY/USD
    // collateral = jpyUbiAmount * 10^oracleDecimals / price
    // Then adjust from 18 decimals to collateral decimals
    uint256 collateralE18 = (jpyUbiAmount * (10 ** oracleDecimals)) / uint256(price);
    uint256 grossCollateral = collateralE18 / (10 ** (18 - colDecimals));

    // Apply sell fee
    uint256 fee = (grossCollateral * sellFee) / BPS_PRECISION;
    collateralAmount = grossCollateral - fee;

    if (collateralAmount < minCollateralOut) revert InsufficientOutput();

    // Burn jUBC from seller (GhoToken tracks bucket level automatically)
    IERC20(address(GHO_TOKEN)).safeTransferFrom(msg.sender, address(this), jpyUbiAmount);
    GHO_TOKEN.burn(jpyUbiAmount);

    // Transfer collateral from treasury to seller
    // Note: Treasury must have approved this contract or use a pull pattern
    IERC20(collateral).safeTransferFrom(_ghoTreasury, msg.sender, collateralAmount);

    emit OracleBuyback(msg.sender, collateral, jpyUbiAmount, collateralAmount, fee, price);
  }

  /**
   * @notice Get a quote for buying jUBC
   * @param collateral The collateral token
   * @param collateralAmount Amount of collateral to spend
   * @return jpyUbiAmount Expected jUBC output (after fees)
   * @return fee Fee amount in jUBC
   */
  function quoteBuyJpyUbi(
    address collateral,
    uint256 collateralAmount
  ) external view returns (uint256 jpyUbiAmount, uint256 fee) {
    (int256 price, uint8 oracleDecimals) = _getOraclePrice();
    uint8 colDecimals = collaterals[collateral].decimals;

    uint256 collateralE18 = collateralAmount * (10 ** (18 - colDecimals));
    uint256 grossAmount = (collateralE18 * uint256(price)) / (10 ** oracleDecimals);

    fee = (grossAmount * buyFee) / BPS_PRECISION;
    jpyUbiAmount = grossAmount - fee;
  }

  /**
   * @notice Get a quote for selling jUBC
   * @param collateral The collateral token to receive
   * @param jpyUbiAmount Amount of jUBC to sell
   * @return collateralAmount Expected collateral output (after fees)
   * @return fee Fee amount in collateral
   */
  function quoteSellJpyUbi(
    address collateral,
    uint256 jpyUbiAmount
  ) external view returns (uint256 collateralAmount, uint256 fee) {
    (int256 price, uint8 oracleDecimals) = _getOraclePrice();
    uint8 colDecimals = collaterals[collateral].decimals;

    uint256 collateralE18 = (jpyUbiAmount * (10 ** oracleDecimals)) / uint256(price);
    uint256 grossAmount = collateralE18 / (10 ** (18 - colDecimals));

    fee = (grossAmount * sellFee) / BPS_PRECISION;
    collateralAmount = grossAmount - fee;
  }

  // ============ UniV3 Liquidity Management ============

  /**
   * @notice Add liquidity to a UniV3 pool
   * @dev Creates a new position NFT
   */
  function addLiquidity(
    address collateral,
    int24 tickLower,
    int24 tickUpper,
    uint24 feeTier,
    uint256 jpyUbiAmount,
    uint256 collateralAmount,
    uint256 jpyUbiMin,
    uint256 collateralMin
  ) external onlyOwner nonReentrant whenLiquidityOpsNotPaused returns (uint256 tokenId, uint128 liquidity) {
    if (!collaterals[collateral].allowed) revert CollateralNotAllowed();

    address token0;
    address token1;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;

    // Determine token ordering (Uni V3 requires token0 < token1)
    if (address(GHO_TOKEN) < collateral) {
      token0 = address(GHO_TOKEN);
      token1 = collateral;
      amount0Desired = jpyUbiAmount;
      amount1Desired = collateralAmount;
      amount0Min = jpyUbiMin;
      amount1Min = collateralMin;
    } else {
      token0 = collateral;
      token1 = address(GHO_TOKEN);
      amount0Desired = collateralAmount;
      amount1Desired = jpyUbiAmount;
      amount0Min = collateralMin;
      amount1Min = jpyUbiMin;
    }

    // Approve position manager
    IERC20(token0).approve(address(univ3Positions), amount0Desired);
    IERC20(token1).approve(address(univ3Positions), amount1Desired);

    INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
      token0: token0,
      token1: token1,
      fee: feeTier,
      tickLower: tickLower,
      tickUpper: tickUpper,
      amount0Desired: amount0Desired,
      amount1Desired: amount1Desired,
      amount0Min: amount0Min,
      amount1Min: amount1Min,
      recipient: address(this),
      deadline: block.timestamp
    });

    uint256 amount0;
    uint256 amount1;
    (tokenId, liquidity, amount0, amount1) = univ3Positions.mint(params);

    // Track position
    Position memory pos = Position({
      tokenId: tokenId,
      collateral: collateral,
      liquidity: liquidity,
      tickLower: tickLower,
      tickUpper: tickUpper,
      feeTier: feeTier
    });
    tokenIdToIndex[tokenId] = positions.length;
    positions.push(pos);

    uint256 jpyUbiUsed = address(GHO_TOKEN) < collateral ? amount0 : amount1;
    uint256 collateralUsed = address(GHO_TOKEN) < collateral ? amount1 : amount0;

    emit LiquidityAdded(tokenId, collateral, jpyUbiUsed, collateralUsed, liquidity);
  }

  /**
   * @notice Remove liquidity from a UniV3 position
   */
  function removeLiquidity(
    uint256 tokenId,
    uint128 liquidityToRemove,
    uint256 amount0Min,
    uint256 amount1Min
  ) external onlyOwner nonReentrant whenLiquidityOpsNotPaused returns (uint256 amount0, uint256 amount1) {
    uint256 index = tokenIdToIndex[tokenId];
    Position storage pos = positions[index];
    if (pos.tokenId != tokenId) revert PositionNotFound();

    INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
      tokenId: tokenId,
      liquidity: liquidityToRemove,
      amount0Min: amount0Min,
      amount1Min: amount1Min,
      deadline: block.timestamp
    });

    (amount0, amount1) = univ3Positions.decreaseLiquidity(params);

    // Collect the tokens
    INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
      tokenId: tokenId,
      recipient: address(this),
      amount0Max: type(uint128).max,
      amount1Max: type(uint128).max
    });
    univ3Positions.collect(collectParams);

    // Update position
    pos.liquidity -= liquidityToRemove;

    // If fully removed, delete position
    if (pos.liquidity == 0) {
      univ3Positions.burn(tokenId);
      _removePosition(index);
    }

    uint256 jpyUbiReceived = address(GHO_TOKEN) < pos.collateral ? amount0 : amount1;
    uint256 collateralReceived = address(GHO_TOKEN) < pos.collateral ? amount1 : amount0;

    emit LiquidityRemoved(tokenId, jpyUbiReceived, collateralReceived);
  }

  /**
   * @notice Collect fees from all positions
   */
  function collectAllFees() external onlyOwner nonReentrant {
    for (uint256 i = 0; i < positions.length; i++) {
      _collectFees(positions[i].tokenId);
    }
  }

  /**
   * @notice Collect fees from a specific position
   */
  function collectFees(uint256 tokenId) external onlyOwner nonReentrant {
    _collectFees(tokenId);
  }

  function _collectFees(uint256 tokenId) internal {
    INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
      tokenId: tokenId,
      recipient: _ghoTreasury,
      amount0Max: type(uint128).max,
      amount1Max: type(uint128).max
    });

    (uint256 amount0, uint256 amount1) = univ3Positions.collect(params);
    emit FeesCollected(tokenId, amount0, amount1);
  }

  /**
   * @notice Swap tokens using UniV3 router
   */
  function swap(
    address tokenIn,
    address tokenOut,
    uint24 feeTier,
    uint256 amountIn,
    uint256 amountOutMin,
    uint160 sqrtPriceLimitX96
  ) external onlyOwner nonReentrant whenLiquidityOpsNotPaused returns (uint256 amountOut) {
    IERC20(tokenIn).approve(address(univ3Router), amountIn);

    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
      tokenIn: tokenIn,
      tokenOut: tokenOut,
      fee: feeTier,
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: amountIn,
      amountOutMinimum: amountOutMin,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    amountOut = univ3Router.exactInputSingle(params);
  }

  // ============ Admin Functions ============

  function addCollateral(address collateral, uint8 decimals) external onlyOwner {
    if (collateral == address(0)) revert ZeroAddress();
    if (collaterals[collateral].allowed) revert CollateralAlreadyAllowed();

    collaterals[collateral] = CollateralConfig({allowed: true, decimals: decimals});
    collateralList.push(collateral);

    emit CollateralAdded(collateral, decimals);
  }

  function removeCollateral(address collateral) external onlyOwner {
    if (!collaterals[collateral].allowed) revert CollateralNotAllowed();

    collaterals[collateral].allowed = false;

    // Remove from list
    for (uint256 i = 0; i < collateralList.length; i++) {
      if (collateralList[i] == collateral) {
        collateralList[i] = collateralList[collateralList.length - 1];
        collateralList.pop();
        break;
      }
    }

    emit CollateralRemoved(collateral);
  }

  function setOracle(address _oracle) external onlyOwner {
    if (_oracle == address(0)) revert ZeroAddress();
    address old = address(jpyUsdOracle);
    jpyUsdOracle = IAggregatorV3(_oracle);
    emit OracleUpdated(old, _oracle);
  }

  function setFees(uint256 _buyFee, uint256 _sellFee) external onlyOwner {
    if (_buyFee > 1000 || _sellFee > 1000) revert InvalidFee(); // Max 10%
    buyFee = _buyFee;
    sellFee = _sellFee;
    emit FeesUpdated(_buyFee, _sellFee);
  }

  function setOracleStalenessThreshold(uint256 _threshold) external onlyOwner {
    oracleStalenessThreshold = _threshold;
  }

  function pauseOracleSales(bool _paused) external onlyOwner {
    oracleSalesPaused = _paused;
  }

  function pauseLiquidityOps(bool _paused) external onlyOwner {
    liquidityOpsPaused = _paused;
  }

  /**
   * @notice Emergency withdraw tokens to treasury
   */
  function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
    IERC20(token).safeTransfer(_ghoTreasury, amount);
  }

  /**
   * @notice Recover ERC721 (NFT positions) to owner
   */
  function recoverERC721(address tokenAddress, uint256 tokenId) external onlyOwner {
    INonfungiblePositionManager(tokenAddress).safeTransferFrom(address(this), owner(), tokenId);
  }

  // ============ View Functions ============

  function getOraclePrice() external view returns (int256 price, uint8 decimals) {
    return _getOraclePrice();
  }

  function getCollaterals() external view returns (address[] memory) {
    return collateralList;
  }

  function getCollateralConfig(address collateral) external view returns (CollateralConfig memory) {
    return collaterals[collateral];
  }

  function getPositions() external view returns (Position[] memory) {
    return positions;
  }

  function numPositions() external view returns (uint256) {
    return positions.length;
  }

  /**
   * @notice Returns the available mint capacity from GhoToken facilitator bucket
   */
  function availableMintCapacity() external view returns (uint256) {
    (uint256 bucketCapacity, uint256 bucketLevel) = GHO_TOKEN.getFacilitatorBucket(address(this));
    return bucketCapacity > bucketLevel ? bucketCapacity - bucketLevel : 0;
  }

  /**
   * @notice Returns the facilitator bucket info from GhoToken
   */
  function getFacilitatorBucket() external view returns (uint256 capacity, uint256 level) {
    return GHO_TOKEN.getFacilitatorBucket(address(this));
  }

  /**
   * @notice Returns accrued fees pending distribution
   */
  function getAccruedFees() external view returns (uint256) {
    return _accruedFees;
  }

  // ============ Internal Functions ============

  function _getOraclePrice() internal view returns (int256 price, uint8 decimals) {
    (
      ,
      int256 answer,
      ,
      uint256 updatedAt,

    ) = jpyUsdOracle.latestRoundData();

    if (block.timestamp - updatedAt > oracleStalenessThreshold) revert OracleStale();
    if (answer <= 0) revert OracleInvalidPrice();

    return (answer, jpyUsdOracle.decimals());
  }

  function _removePosition(uint256 index) internal {
    uint256 lastIndex = positions.length - 1;
    if (index != lastIndex) {
      Position memory lastPosition = positions[lastIndex];
      positions[index] = lastPosition;
      tokenIdToIndex[lastPosition.tokenId] = index;
    }
    positions.pop();
  }

  // Required for receiving NFTs
  function onERC721Received(
    address,
    address,
    uint256,
    bytes calldata
  ) external pure returns (bytes4) {
    return this.onERC721Received.selector;
  }
}
