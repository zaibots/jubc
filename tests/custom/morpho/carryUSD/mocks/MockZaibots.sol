// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IZaibots} from "custom/integrations/morpho/interfaces/IZaibots.sol";
import {IChainlinkAggregatorV3} from "custom/integrations/morpho/interfaces/IChainlinkAutomation.sol";

/**
 * @title MockZaibots
 * @notice Configurable mock of Zaibots lending market for testing
 * @dev Implements IZaibots with full state tracking and test configuration
 */
contract MockZaibots is IZaibots {
    // ═══════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════

    // User balances: user => asset => balance
    mapping(address => mapping(address => uint256)) public collateralBalances;
    mapping(address => mapping(address => uint256)) public debtBalances;

    // LTV configuration: collateral => debt => ltv (18 decimals)
    mapping(address => mapping(address => uint256)) public ltvRatios;

    // Health factor override (0 = calculate dynamically)
    mapping(address => uint256) public healthFactorOverrides;

    // Interest rate simulation
    mapping(address => uint256) public supplyRates; // Ray (27 decimals)
    mapping(address => uint256) public borrowRates; // Ray (27 decimals)

    // Configurable behavior
    bool public shouldRevertOnSupply;
    bool public shouldRevertOnWithdraw;
    bool public shouldRevertOnBorrow;
    bool public shouldRevertOnRepay;

    // Tracking for assertions
    uint256 public totalSupplyCalls;
    uint256 public totalWithdrawCalls;
    uint256 public totalBorrowCalls;
    uint256 public totalRepayCalls;

    // Events for testing
    event Supply(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Borrow(address indexed user, address indexed asset, uint256 amount);
    event Repay(address indexed user, address indexed asset, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════

    function setCollateralBalance(address user, address asset, uint256 amount) external {
        collateralBalances[user][asset] = amount;
    }

    function setDebtBalance(address user, address asset, uint256 amount) external {
        debtBalances[user][asset] = amount;
    }

    function setLTV(address collateral, address debt, uint256 ltv) external {
        ltvRatios[collateral][debt] = ltv;
    }

    function setHealthFactorOverride(address user, uint256 hf) external {
        healthFactorOverrides[user] = hf;
    }

    function setSupplyRate(address asset, uint256 rate) external {
        supplyRates[asset] = rate;
    }

    function setBorrowRate(address asset, uint256 rate) external {
        borrowRates[asset] = rate;
    }

    function setShouldRevert(
        bool _supply,
        bool _withdraw,
        bool _borrow,
        bool _repay
    ) external {
        shouldRevertOnSupply = _supply;
        shouldRevertOnWithdraw = _withdraw;
        shouldRevertOnBorrow = _borrow;
        shouldRevertOnRepay = _repay;
    }

    // ═══════════════════════════════════════════════════════════════════
    // IZaibots IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external override returns (uint256 shares) {
        require(!shouldRevertOnSupply, "MockZaibots: supply reverted");

        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        collateralBalances[onBehalfOf][asset] += amount;
        totalSupplyCalls++;

        shares = amount; // 1:1 for simplicity
        emit Supply(onBehalfOf, asset, amount, shares);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external override returns (uint256) {
        require(!shouldRevertOnWithdraw, "MockZaibots: withdraw reverted");

        uint256 balance = collateralBalances[msg.sender][asset];
        uint256 toWithdraw = amount > balance ? balance : amount;

        collateralBalances[msg.sender][asset] -= toWithdraw;
        IERC20(asset).transfer(to, toWithdraw);
        totalWithdrawCalls++;

        emit Withdraw(msg.sender, asset, toWithdraw, toWithdraw); // shares = amount for simplicity
        return toWithdraw;
    }

    function borrow(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external override {
        require(!shouldRevertOnBorrow, "MockZaibots: borrow reverted");

        debtBalances[onBehalfOf][asset] += amount;
        IERC20(asset).transfer(msg.sender, amount);
        totalBorrowCalls++;

        emit Borrow(onBehalfOf, asset, amount);
    }

    function repay(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external override returns (uint256) {
        require(!shouldRevertOnRepay, "MockZaibots: repay reverted");

        uint256 debt = debtBalances[onBehalfOf][asset];
        uint256 toRepay = amount > debt ? debt : amount;

        IERC20(asset).transferFrom(msg.sender, address(this), toRepay);
        debtBalances[onBehalfOf][asset] -= toRepay;
        totalRepayCalls++;

        emit Repay(onBehalfOf, asset, toRepay);
        return toRepay;
    }

    function getCollateralBalance(
        address user,
        address asset
    ) external view override returns (uint256) {
        return collateralBalances[user][asset];
    }

    function getDebtBalance(
        address user,
        address asset
    ) external view override returns (uint256) {
        return debtBalances[user][asset];
    }

    function getLTV(
        address collateral,
        address debt
    ) external view override returns (uint256) {
        uint256 ltv = ltvRatios[collateral][debt];
        return ltv == 0 ? 0.65e18 : ltv; // Default 65% LTV
    }

    function getHealthFactor(address user) external view override returns (uint256) {
        if (healthFactorOverrides[user] != 0) {
            return healthFactorOverrides[user];
        }
        // Default to healthy (2x)
        return 2e18;
    }

    function getBorrowRate(address asset) external view override returns (uint256) {
        return borrowRates[asset];
    }

    function getSupplyRate(address asset) external view override returns (uint256) {
        return supplyRates[asset];
    }

    function isLiquidatable(address user) external view override returns (bool) {
        uint256 hf = healthFactorOverrides[user];
        if (hf == 0) return false;
        return hf < 1e18;
    }

    mapping(address => uint256) public maxBorrowOverrides;
    mapping(address => bool) public maxBorrowSet;

    // Borrow pair config: debtAsset => (collateralAsset, oracle)
    mapping(address => address) public borrowPairCollateral;
    mapping(address => address) public borrowPairOracle;

    function setMaxBorrow(address user, uint256 amount) external {
        maxBorrowOverrides[user] = amount;
        maxBorrowSet[user] = true;
    }

    function clearMaxBorrowOverride(address user) external {
        maxBorrowOverrides[user] = 0;
        maxBorrowSet[user] = false;
    }

    function configureBorrowPair(address debtAsset, address collateralAsset, address oracle) external {
        borrowPairCollateral[debtAsset] = collateralAsset;
        borrowPairOracle[debtAsset] = oracle;
    }

    function getMaxBorrow(address user, address asset) external view override returns (uint256) {
        if (maxBorrowSet[user]) return maxBorrowOverrides[user];

        address collateralAsset = borrowPairCollateral[asset];
        address oracle = borrowPairOracle[asset];
        if (collateralAsset == address(0) || oracle == address(0)) return type(uint128).max;

        uint256 collateral = collateralBalances[user][collateralAsset];
        uint256 ltv = ltvRatios[collateralAsset][asset];
        if (ltv == 0) ltv = 0.65e18;

        // maxDebtInBase = collateral * LTV / 1e18
        uint256 maxDebtInBase = (collateral * ltv) / 1e18;
        // Convert existing debt to base terms
        uint256 existingDebt = debtBalances[user][asset];
        (, int256 price, , , ) = IChainlinkAggregatorV3(oracle).latestRoundData();
        uint256 existingDebtInBase = (existingDebt * uint256(price)) / 1e20;
        if (existingDebtInBase >= maxDebtInBase) return 0;
        // Convert remaining capacity to debt asset units
        uint256 remainingBase = maxDebtInBase - existingDebtInBase;
        return (remainingBase * 1e20) / uint256(price);
    }

    // ═══════════════════════════════════════════════════════════════════
    // TEST HELPERS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Mint tokens directly to this contract for borrow liquidity
    function fundBorrowLiquidity(address asset, uint256 amount) external {
        // Assumes MockERC20 with mint function
        (bool success, ) = asset.call(abi.encodeWithSignature("mint(address,uint256)", address(this), amount));
        require(success, "MockZaibots: mint failed");
    }

    /// @notice Reset all state for clean test
    function reset() external {
        totalSupplyCalls = 0;
        totalWithdrawCalls = 0;
        totalBorrowCalls = 0;
        totalRepayCalls = 0;
        shouldRevertOnSupply = false;
        shouldRevertOnWithdraw = false;
        shouldRevertOnBorrow = false;
        shouldRevertOnRepay = false;
    }

    /// @notice Simulate interest accrual on debt
    function accrueInterest(address user, address asset, uint256 interestAmount) external {
        debtBalances[user][asset] += interestAmount;
    }
}
