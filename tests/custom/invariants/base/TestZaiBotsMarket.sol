// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {IAaveOracle} from "aave-v3-origin/contracts/interfaces/IAaveOracle.sol";

/**
 * @title IJpyUbi
 * @notice Interface for jpyUBI token (GHO-like with facilitator buckets)
 */
interface IJpyUbi is IERC20 {
    function getFacilitatorsList() external view returns (address[] memory);
    function getFacilitatorBucket(address facilitator) external view returns (uint256 capacity, uint256 level);
}

/**
 * @title TestZaiBotsMarket
 * @notice Base test contract for ZaiBots market invariant tests
 * @dev Provides common setup and helper functions for protocol testing
 *      This is a stub implementation - extend with full market deployment for comprehensive tests
 */
abstract contract TestZaiBotsMarket is Test {
    // ══════════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONTRACTS
    // ══════════════════════════════════════════════════════════════════════════════

    IPool public pool;
    IAaveOracle public oracle;
    IJpyUbi public jpyUbi;
    IERC20 public jpyUbiDebtToken;

    // ══════════════════════════════════════════════════════════════════════════════
    // COLLATERAL TOKENS
    // ══════════════════════════════════════════════════════════════════════════════

    address[] public collateralAssets;
    string[] public collateralSymbols;

    // Specific volatile assets
    IERC20 public virtuals;
    IERC20 public fet;
    IERC20 public render;
    IERC20 public cusd;

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST ACTORS
    // ══════════════════════════════════════════════════════════════════════════════

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public attacker = makeAddr("attacker");

    // ══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ══════════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // This is a stub - in production, deploy or fork the full market here
        // For now, leave pool as address(0) to skip tests gracefully
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // RESERVE CONFIG HELPERS
    // ══════════════════════════════════════════════════════════════════════════════

    function _getLTV(address asset) internal view returns (uint256) {
        if (address(pool) == address(0)) return 0;
        // Get reserve configuration from pool
        // Simplified: return 0 for stub
        return 0;
    }

    function _getLiquidationThreshold(address asset) internal view returns (uint256) {
        if (address(pool) == address(0)) return 0;
        return 0;
    }

    function _isBorrowingEnabled(address asset) internal view returns (bool) {
        if (address(pool) == address(0)) return false;
        return false;
    }

    function _isFlashLoanEnabled(address asset) internal view returns (bool) {
        if (address(pool) == address(0)) return false;
        return false;
    }

    function _getDebtCeiling(address asset) internal view returns (uint256) {
        if (address(pool) == address(0)) return 0;
        return 0;
    }
}
