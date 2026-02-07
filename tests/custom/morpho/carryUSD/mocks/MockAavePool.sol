// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IChainlinkAggregatorV3} from "custom/integrations/morpho/interfaces/IChainlinkAutomation.sol";
import {DataTypes} from "aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol";

/// @title MockPoolToken
/// @notice Minimal ERC20 for tracking aToken/debtToken balances in MockAavePool
contract MockPoolToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    address public pool;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, address _pool) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        pool = _pool;
    }

    modifier onlyPool() {
        require(msg.sender == pool, "MockPoolToken: only pool");
        _;
    }

    function mint(address to, uint256 amount) external onlyPool {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external onlyPool {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/**
 * @title MockAavePool
 * @notice Configurable mock implementing Aave V3 IPool function signatures for testing
 * @dev Implements the exact IPool functions that CarryStrategy calls, plus test helpers.
 *      Does NOT implement the full IPool interface (too many functions to stub).
 */
contract MockAavePool {
    // ═══════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════

    // Mock pool tokens: asset => aToken/debtToken
    mapping(address => MockPoolToken) public aTokens;
    mapping(address => MockPoolToken) public debtTokens;

    // LTV per collateral asset in basis points (e.g., 7500 = 75%)
    mapping(address => uint256) public assetLtvBps;

    // Health factor override (0 = calculate dynamically)
    mapping(address => uint256) public healthFactorOverrides;

    // Borrow cap overrides: user => available borrows in base currency (8 dec)
    mapping(address => uint256) public availBorrowBaseOverrides;
    mapping(address => bool) public availBorrowBaseSet;

    // Borrow pair config for getUserAccountData computation
    address public defaultDebtAsset;
    address public defaultCollateralAsset;
    address public defaultOracle;
    // collateral price in base (8 dec), default 1e8 for stablecoins
    uint256 public collateralPriceBase = 1e8;

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
    event Supply(address indexed user, address indexed asset, uint256 amount);
    event Withdraw(address indexed user, address indexed asset, uint256 amount);
    event Borrow(address indexed user, address indexed asset, uint256 amount);
    event Repay(address indexed user, address indexed asset, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════
    // CONFIGURATION (TEST HELPERS)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Set LTV for a collateral asset (matches old setLTV(collateral, debt, ltv18dec) API)
    /// @param collateral The collateral asset address
    /// @param ltv18dec LTV in 18-decimal format (e.g., 0.75e18 = 75%)
    function setLTV(address collateral, address /* debt */, uint256 ltv18dec) external {
        assetLtvBps[collateral] = (ltv18dec * 10000) / 1e18;
    }

    /// @notice Set LTV directly in basis points
    function setLTVBps(address collateral, uint256 ltvBps) external {
        assetLtvBps[collateral] = ltvBps;
    }

    /// @notice Configure the borrow pair for getUserAccountData computation
    function configureBorrowPair(address debtAsset, address collateralAsset, address oracle) external {
        defaultDebtAsset = debtAsset;
        defaultCollateralAsset = collateralAsset;
        defaultOracle = oracle;
    }

    /// @notice Set the collateral price in base currency (8 decimals)
    function setCollateralPrice(uint256 priceBase) external {
        collateralPriceBase = priceBase;
    }

    function setHealthFactorOverride(address user, uint256 hf) external {
        healthFactorOverrides[user] = hf;
    }

    function setShouldRevert(bool _supply, bool _withdraw, bool _borrow, bool _repay) external {
        shouldRevertOnSupply = _supply;
        shouldRevertOnWithdraw = _withdraw;
        shouldRevertOnBorrow = _borrow;
        shouldRevertOnRepay = _repay;
    }

    /// @notice Set max borrow in debt token units (converted to base for getUserAccountData)
    function setMaxBorrow(address user, uint256 debtTokenAmount) external {
        if (debtTokenAmount == 0) {
            availBorrowBaseOverrides[user] = 0;
            availBorrowBaseSet[user] = true;
            return;
        }
        if (defaultOracle != address(0)) {
            (, int256 price, , , ) = IChainlinkAggregatorV3(defaultOracle).latestRoundData();
            // Convert debt token amount to base currency (8 dec)
            uint8 debtDec = _getOrCreateDebtToken(defaultDebtAsset).decimals();
            availBorrowBaseOverrides[user] = (debtTokenAmount * uint256(price)) / (10 ** debtDec);
        } else {
            // No oracle: store raw (tests should configure oracle first)
            availBorrowBaseOverrides[user] = debtTokenAmount;
        }
        availBorrowBaseSet[user] = true;
    }

    function clearMaxBorrowOverride(address user) external {
        availBorrowBaseOverrides[user] = 0;
        availBorrowBaseSet[user] = false;
    }

    // ═══════════════════════════════════════════════════════════════════
    // IPool FUNCTIONS (called by CarryStrategy)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice IPool.supply - 4 arg version called by CarryStrategy
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /* referralCode */) external {
        _supply(asset, amount, onBehalfOf);
    }

    /// @notice IPool.withdraw - same 3 arg signature as IPool
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(!shouldRevertOnWithdraw, "MockAavePool: withdraw reverted");

        MockPoolToken aToken = _getOrCreateAToken(asset);
        uint256 balance = aToken.balanceOf(msg.sender);
        uint256 toWithdraw = amount > balance ? balance : amount;

        aToken.burn(msg.sender, toWithdraw);
        IERC20(asset).transfer(to, toWithdraw);
        totalWithdrawCalls++;

        emit Withdraw(msg.sender, asset, toWithdraw);
        return toWithdraw;
    }

    /// @notice IPool.borrow - 5 arg version called by CarryStrategy
    function borrow(address asset, uint256 amount, uint256 /* interestRateMode */, uint16 /* referralCode */, address onBehalfOf) external {
        require(!shouldRevertOnBorrow, "MockAavePool: borrow reverted");

        _getOrCreateDebtToken(asset).mint(onBehalfOf, amount);
        IERC20(asset).transfer(msg.sender, amount);
        totalBorrowCalls++;

        emit Borrow(onBehalfOf, asset, amount);
    }

    /// @notice IPool.repay - 4 arg version called by CarryStrategy
    function repay(address asset, uint256 amount, uint256 /* interestRateMode */, address onBehalfOf) external returns (uint256) {
        require(!shouldRevertOnRepay, "MockAavePool: repay reverted");

        MockPoolToken debtToken = _getOrCreateDebtToken(asset);
        uint256 debt = debtToken.balanceOf(onBehalfOf);
        uint256 toRepay = amount > debt ? debt : amount;

        IERC20(asset).transferFrom(msg.sender, address(this), toRepay);
        debtToken.burn(onBehalfOf, toRepay);
        totalRepayCalls++;

        emit Repay(onBehalfOf, asset, toRepay);
        return toRepay;
    }

    /// @notice IPool.getReserveAToken (view-safe — tokens must be pre-created via initReserve or supply/borrow)
    function getReserveAToken(address asset) external view returns (address) {
        return address(aTokens[asset]);
    }

    /// @notice IPool.getReserveVariableDebtToken (view-safe)
    function getReserveVariableDebtToken(address asset) external view returns (address) {
        return address(debtTokens[asset]);
    }

    /// @notice Pre-create aToken + debtToken for an asset so view functions work before first supply/borrow
    function initReserve(address asset) external {
        _getOrCreateAToken(asset);
        _getOrCreateDebtToken(asset);
    }

    /// @notice IPool.getConfiguration - returns DataTypes.ReserveConfigurationMap
    function getConfiguration(address asset) external view returns (DataTypes.ReserveConfigurationMap memory) {
        uint256 ltvBps = assetLtvBps[asset];
        if (ltvBps == 0) ltvBps = 7500; // Default 75%
        // LTV is stored in bits 0-15 of the data field
        return DataTypes.ReserveConfigurationMap({data: ltvBps});
    }

    /// @notice IPool.getUserAccountData
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    ) {
        if (availBorrowBaseSet[user]) {
            availableBorrowsBase = availBorrowBaseOverrides[user];
        } else if (defaultCollateralAsset != address(0) && defaultOracle != address(0)) {
            // Dynamic computation from state
            uint256 collateral = _aTokenBalanceOf(user, defaultCollateralAsset);
            uint8 collDec = _decimalsOf(defaultCollateralAsset);
            // Collateral in base (8 dec): amount * priceBase / 10^decimals
            totalCollateralBase = (collateral * collateralPriceBase) / (10 ** collDec);

            if (defaultDebtAsset != address(0)) {
                uint256 debt = _debtTokenBalanceOf(user, defaultDebtAsset);
                if (debt > 0) {
                    (, int256 debtPrice, , , ) = IChainlinkAggregatorV3(defaultOracle).latestRoundData();
                    uint8 debtDec = _decimalsOf(defaultDebtAsset);
                    totalDebtBase = (debt * uint256(debtPrice)) / (10 ** debtDec);
                }
            }

            uint256 ltvBps = assetLtvBps[defaultCollateralAsset];
            if (ltvBps == 0) ltvBps = 7500;
            uint256 borrowCap = (totalCollateralBase * ltvBps) / 10000;
            availableBorrowsBase = borrowCap > totalDebtBase ? borrowCap - totalDebtBase : 0;
            ltv = ltvBps;
        } else {
            // No config: return max capacity
            availableBorrowsBase = type(uint128).max;
        }

        healthFactor = healthFactorOverrides[user] != 0 ? healthFactorOverrides[user] : 2e18;
    }

    // ═══════════════════════════════════════════════════════════════════
    // TEST HELPERS (convenience functions for test setup)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice 3-arg supply helper for tests (delegates to IPool 4-arg version)
    function supply(address asset, uint256 amount, address onBehalfOf) external {
        _supply(asset, amount, onBehalfOf);
    }

    /// @notice Get collateral balance (aToken balance) for a user
    function getCollateralBalance(address user, address asset) external view returns (uint256) {
        return _aTokenBalanceOf(user, asset);
    }

    /// @notice Get debt balance (debtToken balance) for a user
    function getDebtBalance(address user, address asset) external view returns (uint256) {
        return _debtTokenBalanceOf(user, asset);
    }

    /// @notice Get LTV in 18-decimal format (matches old IZaibots.getLTV API)
    function getLTV(address collateral, address /* debt */) external view returns (uint256) {
        uint256 ltvBps = assetLtvBps[collateral];
        if (ltvBps == 0) ltvBps = 7500;
        return (ltvBps * 1e18) / 10000;
    }

    /// @notice Fund pool with tokens for borrow liquidity
    function fundBorrowLiquidity(address asset, uint256 amount) external {
        (bool success, ) = asset.call(abi.encodeWithSignature("mint(address,uint256)", address(this), amount));
        require(success, "MockAavePool: mint failed");
    }

    /// @notice Reset tracking counters
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
        _getOrCreateDebtToken(asset).mint(user, interestAmount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    function _supply(address asset, uint256 amount, address onBehalfOf) internal {
        require(!shouldRevertOnSupply, "MockAavePool: supply reverted");

        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        _getOrCreateAToken(asset).mint(onBehalfOf, amount);
        totalSupplyCalls++;

        emit Supply(onBehalfOf, asset, amount);
    }

    function _getOrCreateAToken(address asset) internal returns (MockPoolToken) {
        if (address(aTokens[asset]) == address(0)) {
            uint8 dec = _getDecimals(asset);
            aTokens[asset] = new MockPoolToken("aToken", "aToken", dec, address(this));
        }
        return aTokens[asset];
    }

    function _getOrCreateDebtToken(address asset) internal returns (MockPoolToken) {
        if (address(debtTokens[asset]) == address(0)) {
            uint8 dec = _getDecimals(asset);
            debtTokens[asset] = new MockPoolToken("debtToken", "debtToken", dec, address(this));
        }
        return debtTokens[asset];
    }

    function _aTokenBalanceOf(address user, address asset) internal view returns (uint256) {
        MockPoolToken aToken = aTokens[asset];
        if (address(aToken) == address(0)) return 0;
        return aToken.balanceOf(user);
    }

    function _debtTokenBalanceOf(address user, address asset) internal view returns (uint256) {
        MockPoolToken debtToken = debtTokens[asset];
        if (address(debtToken) == address(0)) return 0;
        return debtToken.balanceOf(user);
    }

    function _decimalsOf(address asset) internal view returns (uint8) {
        MockPoolToken aToken = aTokens[asset];
        if (address(aToken) != address(0)) return aToken.decimals();
        MockPoolToken debtToken = debtTokens[asset];
        if (address(debtToken) != address(0)) return debtToken.decimals();
        return _getDecimals(asset);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
