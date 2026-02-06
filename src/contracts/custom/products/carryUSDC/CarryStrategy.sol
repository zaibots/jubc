// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {ReentrancyGuard} from 'openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol';

import {IChainlinkAggregatorV3} from '../../integrations/morpho/interfaces/IChainlinkAutomation.sol';
import {IMilkman} from '../../integrations/morpho/interfaces/IMilkman.sol';
import {IZaibots} from '../../integrations/morpho/interfaces/IZaibots.sol';
import {ILinearBlockTwapOracle} from './LinearBlockTwapOracle.sol';

/**
 * @title CarryStrategy
 * @notice Configurable leveraged yen-carry trade strategy
 */
contract CarryStrategy is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  enum StrategyType { CONSERVATIVE, MODERATE, AGGRESSIVE }
  enum ShouldRebalance { NONE, REBALANCE, ITERATE, RIPCORD }
  enum SwapState { IDLE, PENDING_LEVER_SWAP, PENDING_DELEVER_SWAP }

  struct Addresses {
    address adapter;
    address zaibots;
    address collateralToken;
    address debtToken;
    address jpyUsdOracle;
    address jpyUsdAggregator;
    address twapOracle;
    address milkman;
    address priceChecker;
  }

  struct LeverageParams {
    uint64 target;
    uint64 min;
    uint64 max;
    uint64 ripcord;
  }

  struct ExecutionParams {
    uint128 maxTradeSize;
    uint32 twapCooldown;
    uint16 slippageBps;
    uint32 rebalanceInterval;
    uint64 recenterSpeed;
  }

  struct IncentiveParams {
    uint16 slippageBps;
    uint16 twapCooldown;
    uint128 maxTrade;
    uint96 etherReward;
  }

  string public name;
  StrategyType public strategyType;
  Addresses public addr;
  LeverageParams public leverage;
  ExecutionParams public execution;
  IncentiveParams public incentive;

  SwapState public swapState;
  uint64 public twapLeverageRatio;
  uint64 public lastRebalanceTs;
  uint64 public lastTradeTs;
  uint64 public pendingSwapTs;
  uint128 public pendingSwapAmount;
  uint128 public pendingSwapExpectedOutput;

  mapping(address => bool) public isAllowedCaller;
  address public operator;
  bool public isActive;

  uint256 public constant FULL_PRECISION = 1e18;
  uint256 public constant SWAP_TIMEOUT = 30 minutes;
  uint256 public constant MAX_BPS = 10000;

  event Engaged(uint256 collateral, uint256 targetLeverage);
  event Disengaged(uint256 collateral);
  event Rebalanced(uint256 fromLeverage, uint256 toLeverage, bool isLever);
  event Ripcorded(address indexed caller, uint256 leverage, uint256 reward);
  event AssetsReceived(uint256 amount);
  event AssetsWithdrawn(uint256 amount);
  event SwapCompleted(SwapState swapType, uint256 amount);
  event SwapCancelled(SwapState swapType, uint256 pendingAmount);
  event LTVSynced(uint256 currentLTV, bool stillValid);
  event StrategyAutoDeactivated(string reason);

  error NotAllowedCaller();
  error NotOperator();
  error NotAdapter();
  error SwapPending();
  error SwapNotPending();
  error SwapNotTimedOut();
  error LeverageTooHigh();
  error LeverageTooLow();
  error RebalanceIntervalNotElapsed();
  error TwapNotActive();
  error StrategyNotActive();
  error AlreadyEngaged();
  error NotEngaged();
  error InsufficientEtherReward();
  error InsufficientAssets();
  error LeverageExceedsLTVLimit();
  error SwapOutputTooLow();

  modifier onlyAllowedCaller() {
    if (!isAllowedCaller[msg.sender] && msg.sender != operator && msg.sender != owner()) revert NotAllowedCaller();
    _;
  }

  modifier onlyOperator() {
    if (msg.sender != operator && msg.sender != owner()) revert NotOperator();
    _;
  }

  modifier onlyAdapter() {
    if (msg.sender != addr.adapter) revert NotAdapter();
    _;
  }

  modifier onlyEOA() {
    require(msg.sender == tx.origin, 'Not EOA');
    _;
  }

  modifier whenActive() {
    if (!isActive) revert StrategyNotActive();
    _;
  }

  modifier whenNoSwap() {
    if (swapState != SwapState.IDLE) revert SwapPending();
    _;
  }

  constructor(
    string memory _name,
    StrategyType _type,
    Addresses memory _addresses,
    uint64[4] memory _leverage,
    ExecutionParams memory _execution,
    IncentiveParams memory _incentive
  ) Ownable(msg.sender) {
    name = _name;
    strategyType = _type;
    addr = _addresses;
    leverage = LeverageParams(_leverage[0], _leverage[1], _leverage[2], _leverage[3]);
    execution = _execution;
    incentive = _incentive;
    operator = msg.sender;
    isActive = true;
    swapState = SwapState.IDLE;
    _validateLeverageParams(_leverage[0], _leverage[2]);
    IERC20(_addresses.collateralToken).approve(_addresses.zaibots, type(uint256).max);
    IERC20(_addresses.debtToken).approve(_addresses.zaibots, type(uint256).max);
    IERC20(_addresses.debtToken).approve(_addresses.milkman, type(uint256).max);
    IERC20(_addresses.collateralToken).approve(_addresses.milkman, type(uint256).max);
  }

  function receiveAssets(uint256 amount) external onlyAdapter nonReentrant {
    IERC20(addr.collateralToken).safeTransferFrom(msg.sender, address(this), amount);
    IZaibots(addr.zaibots).supply(addr.collateralToken, amount, address(this));
    emit AssetsReceived(amount);
  }

  function withdrawAssets(uint256 amount) external onlyAdapter nonReentrant returns (uint256 withdrawn) {
    uint256 available = _getAvailableCollateral();
    uint256 toWithdraw = amount < available ? amount : available;
    if (toWithdraw == 0) revert InsufficientAssets();
    withdrawn = IZaibots(addr.zaibots).withdraw(addr.collateralToken, toWithdraw, msg.sender);
    emit AssetsWithdrawn(withdrawn);
  }

  function engage() external onlyAllowedCaller whenActive whenNoSwap nonReentrant {
    uint256 currentLev = getCurrentLeverageRatio();
    if (currentLev > FULL_PRECISION + 1e16) revert AlreadyEngaged();
    uint256 collateral = _getCollateralBalance();
    if (collateral == 0) revert NotEngaged();
    // Defense-in-depth: verify LTV still supports target leverage
    uint256 ltv = _getLTV();
    if (ltv > 0 && ltv < FULL_PRECISION) {
      uint256 complement = FULL_PRECISION - ltv;
      if (uint256(leverage.target) * complement >= 1e27) revert LeverageExceedsLTVLimit();
    }
    twapLeverageRatio = leverage.target;
    _lever(_calculateLeverAmount());
    emit Engaged(collateral, uint256(leverage.target) * 1e9);
  }

  function rebalance() external onlyEOA onlyAllowedCaller whenActive whenNoSwap nonReentrant {
    ShouldRebalance action = shouldRebalance();
    if (action == ShouldRebalance.NONE || action == ShouldRebalance.ITERATE) revert RebalanceIntervalNotElapsed();
    if (action == ShouldRebalance.RIPCORD) revert LeverageTooHigh();
    uint256 currentLev = getCurrentLeverageRatio();
    uint256 targetLev = _calculateNewLeverageRatio(currentLev);
    if (currentLev > targetLev) {
      _delever(_calculateDeleverAmount(currentLev, targetLev));
      emit Rebalanced(currentLev, targetLev, false);
    } else {
      _lever(_calculateLeverAmount());
      emit Rebalanced(currentLev, targetLev, true);
    }
    lastRebalanceTs = uint64(block.timestamp);
  }

  function iterateRebalance() external onlyEOA onlyAllowedCaller whenActive whenNoSwap nonReentrant {
    if (twapLeverageRatio == 0) revert TwapNotActive();
    if (block.timestamp < lastTradeTs + execution.twapCooldown) revert RebalanceIntervalNotElapsed();
    uint256 currentLev = getCurrentLeverageRatio();
    uint256 twapTarget = uint256(twapLeverageRatio) * 1e9;
    if (currentLev < twapTarget) {
      uint256 leverAmount = _calculateLeverAmount();
      bool fitsInOneTrade = leverAmount <= uint256(execution.maxTradeSize);
      uint256 actualTrade = _lever(leverAmount);
      // Only clear TWAP if full amount fits AND was fully executed (not borrow-capped)
      if (fitsInOneTrade && actualTrade > 0) {
        twapLeverageRatio = 0;
      } else if (swapState == SwapState.IDLE) {
        // No swap was created (zero borrow capacity) — skip but keep TWAP active
        lastTradeTs = uint64(block.timestamp);
        emit Rebalanced(currentLev, twapTarget, true);
        return;
      }
      // else: swap created but capped or multi-trade → TWAP persists
    } else if (currentLev > twapTarget) {
      uint256 deleverAmount = _calculateDeleverAmount(currentLev, twapTarget);
      if (deleverAmount <= uint256(execution.maxTradeSize)) twapLeverageRatio = 0;
      _delever(deleverAmount);
    } else {
      twapLeverageRatio = 0;
    }
    emit Rebalanced(currentLev, twapTarget, currentLev < twapTarget);
  }

  function ripcord() external onlyEOA whenNoSwap nonReentrant {
    uint256 currentLev = getCurrentLeverageRatio();
    if (currentLev < uint256(leverage.ripcord) * 1e9) revert LeverageTooLow();
    uint256 deleverAmount = _min(_calculateDeleverAmount(currentLev, uint256(leverage.max) * 1e9), uint256(incentive.maxTrade));
    _deleverWithSlippage(deleverAmount, incentive.slippageBps);
    uint256 reward = uint256(incentive.etherReward);
    if (address(this).balance < reward) revert InsufficientEtherReward();
    (bool success, ) = msg.sender.call{value: reward}('');
    require(success, 'ETH transfer failed');
    emit Ripcorded(msg.sender, currentLev, reward);
    lastTradeTs = uint64(block.timestamp);
  }

  function completeSwap() external nonReentrant {
    if (swapState == SwapState.IDLE) revert SwapNotPending();
    SwapState completedType = swapState;
    uint128 expectedOutput = pendingSwapExpectedOutput;

    // Effects: clear state BEFORE interactions (CEI pattern)
    swapState = SwapState.IDLE;
    pendingSwapTs = 0;
    pendingSwapAmount = 0;
    pendingSwapExpectedOutput = 0;

    uint256 amount;
    if (completedType == SwapState.PENDING_LEVER_SWAP) {
      amount = IERC20(addr.collateralToken).balanceOf(address(this));
      if (amount > 0 && amount < expectedOutput) revert SwapOutputTooLow();
      if (amount > 0) {
        IZaibots(addr.zaibots).supply(addr.collateralToken, amount, address(this));
      }
    } else {
      amount = IERC20(addr.debtToken).balanceOf(address(this));
      if (amount > 0 && amount < expectedOutput) revert SwapOutputTooLow();
      if (amount > 0) {
        IZaibots(addr.zaibots).repay(addr.debtToken, amount, address(this));
      }
    }
    emit SwapCompleted(completedType, amount);
  }

  function cancelTimedOutSwap() external onlyAllowedCaller nonReentrant {
    if (swapState == SwapState.IDLE) revert SwapNotPending();
    if (block.timestamp < pendingSwapTs + SWAP_TIMEOUT) revert SwapNotTimedOut();
    SwapState cancelledType = swapState;
    uint128 cancelledAmount = pendingSwapAmount;
    swapState = SwapState.IDLE;
    pendingSwapTs = 0;
    pendingSwapAmount = 0;
    pendingSwapExpectedOutput = 0;
    emit SwapCancelled(cancelledType, cancelledAmount);
  }

  function getCurrentLeverageRatio() public view returns (uint256) {
    uint256 collateral = _getCollateralBalance();
    if (collateral == 0) return FULL_PRECISION;
    uint256 debt = _getDebtBalanceInBase();
    if (debt == 0) return FULL_PRECISION;
    uint256 equity = collateral > debt ? collateral - debt : 0;
    if (equity == 0) return type(uint256).max;
    return (collateral * FULL_PRECISION) / equity;
  }

  function shouldRebalance() public view returns (ShouldRebalance) {
    if (swapState != SwapState.IDLE) return ShouldRebalance.NONE;
    uint256 currentLev = getCurrentLeverageRatio();
    if (currentLev >= uint256(leverage.ripcord) * 1e9) return ShouldRebalance.RIPCORD;
    if (twapLeverageRatio != 0 && block.timestamp >= lastTradeTs + execution.twapCooldown) return ShouldRebalance.ITERATE;
    if (twapLeverageRatio != 0) return ShouldRebalance.NONE;
    if (currentLev > uint256(leverage.max) * 1e9 || currentLev < uint256(leverage.min) * 1e9) return ShouldRebalance.REBALANCE;
    if (block.timestamp >= lastRebalanceTs + execution.rebalanceInterval) {
      uint256 targetLev = uint256(leverage.target) * 1e9;
      uint256 deviation = currentLev > targetLev ? currentLev - targetLev : targetLev - currentLev;
      if (deviation > 1e16) return ShouldRebalance.REBALANCE;
    }
    return ShouldRebalance.NONE;
  }

  function getRealAssets() public view returns (uint256) {
    uint256 collateral = _getCollateralBalance();
    uint256 debt = _getDebtBalanceInBase();
    uint256 equity = collateral > debt ? collateral - debt : 0;
    if (swapState == SwapState.PENDING_LEVER_SWAP) return equity > pendingSwapAmount ? equity - pendingSwapAmount : 0;
    return equity;
  }

  function isEngaged() external view returns (bool) {
    return getCurrentLeverageRatio() > FULL_PRECISION + 1e16;
  }

  /// @notice Max leverage given current LTV: 1 / (1 - LTV)
  function getMaxAchievableLeverage() public view returns (uint256) {
    uint256 ltv = _getLTV();
    if (ltv == 0) return FULL_PRECISION;
    if (ltv >= FULL_PRECISION) return type(uint256).max;
    return (FULL_PRECISION * FULL_PRECISION) / (FULL_PRECISION - ltv);
  }

  function _lever(uint256 _notionalBase) internal returns (uint256 actualTradeSize) {
    if (_notionalBase == 0) return 0;
    uint256 tradeSize = _min(_notionalBase, execution.maxTradeSize);
    if (_notionalBase > execution.maxTradeSize) twapLeverageRatio = leverage.target;
    uint256 debtToBorrow = _calculateDebtBorrowAmount(tradeSize);
    uint256 maxBorrow = IZaibots(addr.zaibots).getMaxBorrow(address(this), addr.debtToken);
    maxBorrow = (maxBorrow * 95) / 100;
    bool wasCapped = false;
    if (debtToBorrow > maxBorrow) {
      if (maxBorrow == 0) return 0;
      debtToBorrow = maxBorrow;
      wasCapped = true;
    }
    // Pre-borrow projected leverage check
    {
      uint256 safeLev = (getMaxAchievableLeverage() * 95) / 100;
      uint256 currentCollateral = _getCollateralBalance();
      uint256 currentDebt = _getDebtBalanceInBase();
      (, int256 _price, , , ) = IChainlinkAggregatorV3(addr.jpyUsdOracle != address(0) ? addr.jpyUsdOracle : addr.jpyUsdAggregator).latestRoundData();
      uint256 newDebtInBase = currentDebt + (debtToBorrow * uint256(_price)) / 1e20;
      uint256 equity = currentCollateral > newDebtInBase ? currentCollateral - newDebtInBase : 0;
      if (equity > 0) {
        uint256 projectedLev = (currentCollateral * FULL_PRECISION) / equity;
        if (projectedLev > safeLev) {
          // Scale back borrow to stay within safe leverage
          uint256 maxDebtInBase = currentCollateral - (currentCollateral * FULL_PRECISION) / safeLev;
          if (maxDebtInBase <= currentDebt) return 0;
          uint256 allowedNewDebtBase = maxDebtInBase - currentDebt;
          debtToBorrow = (allowedNewDebtBase * 1e20) / uint256(_price);
          if (debtToBorrow == 0) return 0;
          wasCapped = true;
        }
      }
    }
    IZaibots(addr.zaibots).borrow(addr.debtToken, debtToBorrow, address(this));
    // Calculate expected output: JPY→USDC, with 2x slippage buffer
    pendingSwapExpectedOutput = uint128(_calculateExpectedLeverOutput(debtToBorrow));
    bytes memory priceCheckerData = abi.encode(execution.slippageBps, addr.priceChecker);
    IMilkman(addr.milkman).requestSwapExactTokensForTokens(debtToBorrow, IERC20(addr.debtToken), IERC20(addr.collateralToken), address(this), addr.priceChecker, priceCheckerData);
    swapState = SwapState.PENDING_LEVER_SWAP;
    pendingSwapTs = uint64(block.timestamp);
    pendingSwapAmount = uint128(tradeSize);
    lastTradeTs = uint64(block.timestamp);
    // Return 0 when capped to signal partial execution; use swapState to check if swap was created
    return wasCapped ? 0 : tradeSize;
  }

  function _delever(uint256 _notionalBase) internal {
    _deleverWithSlippage(_notionalBase, execution.slippageBps);
  }

  function _deleverWithSlippage(uint256 _notionalBase, uint16 _slippageBps) internal {
    if (_notionalBase == 0) return;
    uint256 tradeSize = _min(_notionalBase, execution.maxTradeSize);
    IZaibots(addr.zaibots).withdraw(addr.collateralToken, tradeSize, address(this));
    // Calculate expected output: USDC→JPY, with 2x slippage buffer
    pendingSwapExpectedOutput = uint128(_calculateExpectedDeleverOutput(tradeSize));
    bytes memory priceCheckerData = abi.encode(_slippageBps, addr.priceChecker);
    IMilkman(addr.milkman).requestSwapExactTokensForTokens(tradeSize, IERC20(addr.collateralToken), IERC20(addr.debtToken), address(this), addr.priceChecker, priceCheckerData);
    swapState = SwapState.PENDING_DELEVER_SWAP;
    pendingSwapTs = uint64(block.timestamp);
    pendingSwapAmount = uint128(tradeSize);
    lastTradeTs = uint64(block.timestamp);
  }

  function _getCollateralBalance() internal view returns (uint256) {
    return IZaibots(addr.zaibots).getCollateralBalance(address(this), addr.collateralToken);
  }

  function _getDebtBalance() internal view returns (uint256) {
    return IZaibots(addr.zaibots).getDebtBalance(address(this), addr.debtToken);
  }

  function _getDebtBalanceInBase() internal view returns (uint256) {
    uint256 debtBalance = _getDebtBalance();
    if (debtBalance == 0) return 0;
    (, int256 price, , , ) = IChainlinkAggregatorV3(addr.jpyUsdOracle != address(0) ? addr.jpyUsdOracle : addr.jpyUsdAggregator).latestRoundData();
    return (debtBalance * uint256(price)) / 1e20;
  }

  function _getAvailableCollateral() internal view returns (uint256) {
    uint256 collateral = _getCollateralBalance();
    uint256 debt = _getDebtBalanceInBase();
    uint256 ltv = _getLTV();
    uint256 minCollateral = (debt * FULL_PRECISION) / ltv;
    return collateral > minCollateral ? collateral - minCollateral : 0;
  }

  function _getLTV() internal view returns (uint256) {
    return IZaibots(addr.zaibots).getLTV(addr.collateralToken, addr.debtToken);
  }

  function _calculateDebtBorrowAmount(uint256 baseAmount) internal view returns (uint256) {
    (, int256 price, , , ) = IChainlinkAggregatorV3(addr.jpyUsdOracle != address(0) ? addr.jpyUsdOracle : addr.jpyUsdAggregator).latestRoundData();
    uint256 jpyAmount = (baseAmount * 1e20) / uint256(price);
    uint256 ltv = _getLTV();
    return (jpyAmount * ltv) / FULL_PRECISION;
  }

  function _calculateNewLeverageRatio(uint256 _currentLev) internal view returns (uint256) {
    uint256 target = uint256(leverage.target) * 1e9;
    uint256 speed = uint256(execution.recenterSpeed) * 1e9;
    if (_currentLev > target) return _currentLev - ((_currentLev - target) * speed) / FULL_PRECISION;
    return _currentLev + ((target - _currentLev) * speed) / FULL_PRECISION;
  }

  function _calculateLeverAmount() internal view returns (uint256) {
    uint256 collateral = _getCollateralBalance();
    uint256 currentLev = getCurrentLeverageRatio();
    uint256 targetLev = uint256(leverage.target) * 1e9;
    // Cap to 95% of theoretical max to prevent exceeding LTV
    uint256 safeLev = (getMaxAchievableLeverage() * 95) / 100;
    if (targetLev > safeLev) targetLev = safeLev;
    if (currentLev >= targetLev) return 0;
    uint256 debt = _getDebtBalanceInBase();
    uint256 equity = collateral > debt ? collateral - debt : 0;
    uint256 targetCollateral = (equity * targetLev) / FULL_PRECISION;
    return targetCollateral > collateral ? targetCollateral - collateral : 0;
  }

  function _calculateDeleverAmount(uint256 _currentLev, uint256 _targetLev) internal view returns (uint256) {
    uint256 collateral = _getCollateralBalance();
    uint256 debt = _getDebtBalanceInBase();
    uint256 equity = collateral > debt ? collateral - debt : 0;
    uint256 targetCollateral = (equity * _targetLev) / FULL_PRECISION;
    return collateral > targetCollateral ? collateral - targetCollateral : 0;
  }

  function _validateLeverageParams(uint64 target, uint64 maxLev) internal view {
    if (addr.zaibots == address(0) || addr.zaibots == address(1)) return;
    uint256 ltv = IZaibots(addr.zaibots).getLTV(addr.collateralToken, addr.debtToken);
    if (ltv == 0 || ltv >= FULL_PRECISION) return;
    uint256 complement = FULL_PRECISION - ltv;
    if (uint256(target) * complement >= 1e27) revert LeverageExceedsLTVLimit();
    if (uint256(maxLev) * complement >= 1e27) revert LeverageExceedsLTVLimit();
  }

  /// @notice Expected USDC output from selling jpyAmount of debt token (lever: JPY→USDC)
  function _calculateExpectedLeverOutput(uint256 jpyAmount) internal view returns (uint256) {
    (, int256 price, , , ) = IChainlinkAggregatorV3(addr.jpyUsdOracle != address(0) ? addr.jpyUsdOracle : addr.jpyUsdAggregator).latestRoundData();
    uint256 usdcAmount = (jpyAmount * uint256(price)) / 1e20;
    // Apply 2x slippage tolerance as minimum output threshold
    return (usdcAmount * (MAX_BPS - uint256(execution.slippageBps) * 2)) / MAX_BPS;
  }

  /// @notice Expected JPY output from selling usdcAmount of collateral (delever: USDC→JPY)
  function _calculateExpectedDeleverOutput(uint256 usdcAmount) internal view returns (uint256) {
    (, int256 price, , , ) = IChainlinkAggregatorV3(addr.jpyUsdOracle != address(0) ? addr.jpyUsdOracle : addr.jpyUsdAggregator).latestRoundData();
    uint256 jpyAmount = (usdcAmount * 1e20) / uint256(price);
    // Apply 2x slippage tolerance as minimum output threshold
    return (jpyAmount * (MAX_BPS - uint256(execution.slippageBps) * 2)) / MAX_BPS;
  }

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

  function setActive(bool _isActive) external onlyOperator {
    isActive = _isActive;
  }

  /// @notice Permissionless — re-validate LTV, auto-deactivate if target is unreachable
  function syncLTV() external returns (bool valid) {
    uint256 ltv = _getLTV();
    if (ltv == 0 || ltv >= FULL_PRECISION) { emit LTVSynced(ltv, true); return true; }
    uint256 complement = FULL_PRECISION - ltv;
    valid = uint256(leverage.target) * complement < 1e27
         && uint256(leverage.max) * complement < 1e27;
    if (!valid && isActive) {
      isActive = false;
      emit StrategyAutoDeactivated("LTV no longer supports target leverage");
    }
    emit LTVSynced(ltv, valid);
  }

  /// @notice View: check if current LTV still supports our leverage params
  function isLTVValid() external view returns (bool) {
    uint256 ltv = _getLTV();
    if (ltv == 0 || ltv >= FULL_PRECISION) return true;
    uint256 complement = FULL_PRECISION - ltv;
    return uint256(leverage.target) * complement < 1e27
        && uint256(leverage.max) * complement < 1e27;
  }

  function setAllowedCaller(address _caller, bool _isAllowed) external onlyOperator {
    isAllowedCaller[_caller] = _isAllowed;
  }

  function setOperator(address _operator) external onlyOwner {
    operator = _operator;
  }

  function setAdapter(address _adapter) external onlyOwner {
    addr.adapter = _adapter;
  }

  receive() external payable {}

  function withdrawEther(uint256 _amount) external onlyOperator {
    (bool success, ) = msg.sender.call{value: _amount}('');
    require(success, 'ETH transfer failed');
  }
}
