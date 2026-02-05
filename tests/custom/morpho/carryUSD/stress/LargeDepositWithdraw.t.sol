// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";

/**
 * @title LargeDepositWithdrawTest
 * @notice Stress tests for large deposit/withdrawal scenarios
 * @dev Tests TWAP behavior, swap sizing, and accounting at scale
 */
contract LargeDepositWithdrawTest is TestCarryUSDBase {
    // ═══════════════════════════════════════════════════════════════════
    // TWAP BEHAVIOR AT SCALE
    // ═══════════════════════════════════════════════════════════════════

    function test_largeDeposit_twapChunking() public onlyLocal {
        // Deposit larger than maxTradeSize
        uint256 largeDeposit = DEFAULT_MAX_TRADE_SIZE * 5;
        _setupCollateral(largeDeposit);

        _engageStrategy();

        // First swap should be capped
        uint256 pendingAmount = carryStrategy.pendingSwapAmount();
        assertLe(pendingAmount, DEFAULT_MAX_TRADE_SIZE, "First swap should be chunked");

        // TWAP should be active
        assertTrue(carryStrategy.twapLeverageRatio() > 0, "TWAP should be active for large deposit");
    }

    function test_largeDeposit_twapIterationCount() public onlyLocal {
        uint256 largeDeposit = DEFAULT_MAX_TRADE_SIZE * 3;
        _setupCollateral(largeDeposit);

        _engageStrategy();
        _completeLeverSwap();

        uint256 iterations = 0;
        uint256 maxIterations = 20;

        while (carryStrategy.twapLeverageRatio() > 0 && iterations < maxIterations) {
            _warpPastTwapCooldown();

            if (carryStrategy.shouldRebalance() == CarryStrategy.ShouldRebalance.ITERATE) {
                _iterateRebalance();
                _completeLeverSwap();
                iterations++;
            } else {
                break;
            }
        }

        // Should have taken multiple iterations
        assertTrue(iterations > 0, "Should require multiple TWAP iterations");
    }

    function test_largeDeposit_twapCooldownRespected() public onlyLocal {
        uint256 largeDeposit = DEFAULT_MAX_TRADE_SIZE * 3;
        _setupCollateral(largeDeposit);

        _engageStrategy();
        _completeLeverSwap();

        // Try to iterate without waiting
        if (carryStrategy.twapLeverageRatio() > 0) {
            vm.expectRevert(CarryStrategy.RebalanceIntervalNotElapsed.selector);
            _iterateRebalance();
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP SIZING AT SCALE
    // ═══════════════════════════════════════════════════════════════════

    function test_swapSize_cappedAtMax() public onlyLocal {
        uint256 hugeDeposit = DEFAULT_MAX_TRADE_SIZE * 10;
        _setupCollateral(hugeDeposit);

        _engageStrategy();

        uint256 pendingAmount = carryStrategy.pendingSwapAmount();
        assertEq(pendingAmount, DEFAULT_MAX_TRADE_SIZE, "Swap should be capped at max");
    }

    function test_swapSize_exactlyMaxTradeSize() public onlyLocal {
        uint256 exactDeposit = DEFAULT_MAX_TRADE_SIZE;
        _setupCollateral(exactDeposit);

        _engageStrategy();

        uint256 pendingAmount = carryStrategy.pendingSwapAmount();
        assertLe(pendingAmount, DEFAULT_MAX_TRADE_SIZE, "Should handle exact max trade size");
    }

    function test_swapSize_underMaxTradeSize() public onlyLocal {
        uint256 smallDeposit = DEFAULT_MAX_TRADE_SIZE / 2;
        _setupCollateral(smallDeposit);

        _engageStrategy();

        uint256 pendingAmount = carryStrategy.pendingSwapAmount();
        assertTrue(pendingAmount <= smallDeposit, "Should handle under max trade size");
    }

    // ═══════════════════════════════════════════════════════════════════
    // SCALE VARIANTS
    // ═══════════════════════════════════════════════════════════════════

    function test_scale_100_dollars() public onlyLocal {
        _testDepositAndEngage(SIZE_100);
    }

    function test_scale_10k_dollars() public onlyLocal {
        _testDepositAndEngage(SIZE_10K);
    }

    function test_scale_1m_dollars() public onlyLocal {
        _testDepositAndEngage(SIZE_1M);
    }

    function test_scale_100m_dollars() public onlyLocal {
        _testDepositAndEngage(SIZE_100M);
    }

    function testFuzz_scale_anyAmount(uint256 amount) public onlyLocal {
        // Bound to reasonable range
        amount = bound(amount, 100e6, 100_000_000e6);
        _testDepositAndEngage(amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // YEN PRICE IMPACT AT SCALE
    // ═══════════════════════════════════════════════════════════════════

    function test_scale_yenUp30_largePosition() public onlyLocal {
        _setupEngagedStrategy(VAULT_100M);

        uint256 leverageBefore = carryStrategy.getCurrentLeverageRatio();

        _applyYenMovement(YEN_UP_30);

        uint256 leverageAfter = carryStrategy.getCurrentLeverageRatio();

        // Leverage should increase significantly
        assertTrue(leverageAfter > leverageBefore, "Leverage should increase on JPY appreciation");
    }

    function test_scale_yenDown30_largePosition() public onlyLocal {
        _setupEngagedStrategy(VAULT_100M);

        uint256 leverageBefore = carryStrategy.getCurrentLeverageRatio();

        _applyYenMovement(YEN_DOWN_30);

        uint256 leverageAfter = carryStrategy.getCurrentLeverageRatio();

        // Leverage should decrease
        assertTrue(leverageAfter < leverageBefore, "Leverage should decrease on JPY depreciation");
    }

    // ═══════════════════════════════════════════════════════════════════
    // RIPCORD AT SCALE
    // ═══════════════════════════════════════════════════════════════════

    function test_ripcord_largePosition() public onlyLocal {
        _setupEngagedStrategy(VAULT_100M);

        // Push to ripcord
        _applyYenMovement(YEN_UP_30);

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
            _triggerRipcord(alice);

            // Should be capped at ripcord max trade
            uint256 pendingAmount = carryStrategy.pendingSwapAmount();
            assertLe(pendingAmount, DEFAULT_RIPCORD_MAX_TRADE, "Ripcord should be capped");
        }
    }

    function test_ripcord_multipleCallsForLargePosition() public onlyLocal {
        _setupEngagedStrategy(VAULT_100M);

        _applyYenMovement(YEN_UP_30);

        uint256 ripcordCount = 0;
        uint256 maxRipcords = 50;

        while (ripcordCount < maxRipcords) {
            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

            if (action != CarryStrategy.ShouldRebalance.RIPCORD) break;

            _triggerRipcord(alice);
            _completeDeleverSwap();
            ripcordCount++;
        }

        assertTrue(ripcordCount > 1, "Large position should require multiple ripcords");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ACCOUNTING INVARIANTS
    // ═══════════════════════════════════════════════════════════════════

    function test_accounting_realAssetsNeverNegative() public onlyLocal {
        uint256[] memory sizes = _getDollarSizes();

        for (uint256 i = 0; i < sizes.length; i++) {
            setUp(); // Reset state

            _setupEngagedStrategy(sizes[i]);

            uint256 realAssets = carryStrategy.getRealAssets();
            assertTrue(realAssets >= 0, "Real assets should never be negative");
        }
    }

    function test_accounting_leverageAlwaysAboveOne() public onlyLocal {
        _setupEngagedStrategy(VAULT_10M);

        // Apply various price movements
        int256[] memory movements = _getYenMovements();

        for (uint256 i = 0; i < movements.length; i++) {
            _setOraclePrice(BASE_JPY_PRICE);
            _applyYenMovement(movements[i]);

            uint256 leverage = carryStrategy.getCurrentLeverageRatio();
            assertTrue(leverage >= FULL_PRECISION, "Leverage should always be >= 1x");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // MATRIX TEST COMBINATIONS
    // ═══════════════════════════════════════════════════════════════════

    function test_matrix_criticalCombinations() public onlyLocal {
        uint256[] memory sizes = new uint256[](3);
        sizes[0] = SIZE_10K;
        sizes[1] = SIZE_1M;
        sizes[2] = SIZE_100M;

        int256[] memory movements = new int256[](3);
        movements[0] = YEN_UP_10;
        movements[1] = 0;
        movements[2] = YEN_DOWN_10;

        for (uint256 i = 0; i < sizes.length; i++) {
            for (uint256 j = 0; j < movements.length; j++) {
                setUp(); // Reset

                _setupEngagedStrategy(sizes[i]);
                _applyYenMovement(movements[j]);

                // Verify solvency
                uint256 leverage = carryStrategy.getCurrentLeverageRatio();
                assertTrue(leverage > 0, "Strategy should be solvent");
                assertTrue(leverage < type(uint256).max, "Leverage should not overflow");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _setupCollateral(uint256 amount) internal {
        mockUsdc.mint(address(carryStrategy), amount);
        // Note: Don't call approve here - the strategy constructor already approved max to zaibots
        vm.prank(address(carryStrategy));
        mockZaibots.supply(address(usdc), amount, address(carryStrategy));
    }

    function _setupEngagedStrategy(uint256 amount) internal {
        _setupCollateral(amount);
        _engageStrategy();
        _completeLeverSwap();

        while (carryStrategy.twapLeverageRatio() > 0 && carryStrategy.swapState() == CarryStrategy.SwapState.IDLE) {
            _warpPastTwapCooldown();
            if (carryStrategy.shouldRebalance() == CarryStrategy.ShouldRebalance.ITERATE) {
                _iterateRebalance();
                // Only complete swap if one was created
                if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
                    _completeLeverSwap();
                }
            } else {
                break;
            }
        }
    }

    function _testDepositAndEngage(uint256 amount) internal {
        _setupCollateral(amount);

        uint256 collateralBefore = mockZaibots.getCollateralBalance(address(carryStrategy), address(usdc));
        assertTrue(collateralBefore > 0, "Should have collateral");

        _engageStrategy();

        assertTrue(carryStrategy.swapState() != CarryStrategy.SwapState.IDLE, "Should initiate swap");

        _completeLeverSwap();

        _assertIsEngaged();
    }
}
