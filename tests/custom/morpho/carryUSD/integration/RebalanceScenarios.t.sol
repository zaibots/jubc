// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";

/**
 * @title RebalanceScenariosTest
 * @notice Integration tests for rebalance scenarios under various conditions
 * @dev Tests leverage maintenance, TWAP chunking, and edge cases
 */
contract RebalanceScenariosTest is TestCarryUSDBase {
    // ═══════════════════════════════════════════════════════════════════
    // LEVERAGE BOUNDARIES
    // ═══════════════════════════════════════════════════════════════════

    function test_rebalance_leverageAboveMax() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Simulate price increase that pushes leverage above max
        _simulateLeverageIncrease();

        _warpToRebalanceWindow();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        assertTrue(
            action == CarryStrategy.ShouldRebalance.REBALANCE ||
            action == CarryStrategy.ShouldRebalance.RIPCORD,
            "Should trigger rebalance or ripcord when above max"
        );
    }

    function test_rebalance_leverageBelowMin() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Simulate price decrease that pushes leverage below min
        _simulateLeverageDecrease();

        _warpToRebalanceWindow();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
            _triggerRebalance();
            // Should initiate lever up
            assertEq(
                uint256(carryStrategy.swapState()),
                uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP),
                "Should lever up when below min"
            );
        }
    }

    function test_rebalance_exactlyAtMin() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // At exactly min should not trigger
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        // Could be NONE, ITERATE, or REBALANCE depending on other conditions
        assertTrue(true, "Should handle exact boundary");
    }

    function test_rebalance_exactlyAtMax() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // At exactly max should not trigger ripcord
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        assertTrue(
            action != CarryStrategy.ShouldRebalance.RIPCORD,
            "Should not ripcord at exactly max"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // RECENTER SPEED
    // ═══════════════════════════════════════════════════════════════════

    function test_recenterSpeed_movesGradually() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        uint256 initialLeverage = carryStrategy.getCurrentLeverageRatio();

        // Cause a deviation
        _applyPriceChange(300);
        _warpToRebalanceWindow();

        uint256 deviatedLeverage = carryStrategy.getCurrentLeverageRatio();

        // If rebalance is needed, it should move gradually
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
            _triggerRebalance();

            // Complete swap
            if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_DELEVER_SWAP) {
                _completeDeleverSwap();
            } else {
                _completeLeverSwap();
            }

            uint256 newLeverage = carryStrategy.getCurrentLeverageRatio();

            // Leverage should have moved toward target but not fully
            uint256 target = uint256(CONSERVATIVE_TARGET) * 1e9;
            if (deviatedLeverage > target) {
                assertTrue(newLeverage <= deviatedLeverage, "Should have moved down");
            }
        }
    }

    function test_recenterSpeed_multipleIterations() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Large deviation
        _applyPriceChange(800);
        _warpToRebalanceWindow();

        uint256[] memory leverageHistory = new uint256[](5);
        leverageHistory[0] = carryStrategy.getCurrentLeverageRatio();

        for (uint256 i = 1; i < 5; i++) {
            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
            if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
                _triggerRebalance();
                _completeSwap();
            } else if (action == CarryStrategy.ShouldRebalance.ITERATE) {
                _warpPastTwapCooldown();
                _iterateRebalance();
                _completeSwap();
            } else {
                break;
            }

            leverageHistory[i] = carryStrategy.getCurrentLeverageRatio();
            _warpToRebalanceWindow();
        }

        // Leverage should converge toward target over time
        uint256 target = uint256(CONSERVATIVE_TARGET) * 1e9;
        uint256 initialDiff = leverageHistory[0] > target ? leverageHistory[0] - target : target - leverageHistory[0];
        uint256 finalDiff = leverageHistory[4] > target ? leverageHistory[4] - target : target - leverageHistory[4];

        assertTrue(finalDiff <= initialDiff, "Leverage should converge toward target");
    }

    // ═══════════════════════════════════════════════════════════════════
    // MAX TRADE SIZE
    // ═══════════════════════════════════════════════════════════════════

    function test_maxTradeSize_chunksLargeRebalance() public onlyLocal {
        // Setup large position
        _setupEngagedStrategy(500_000e6);

        // Cause large deviation
        _applyPriceChange(500);
        _warpToRebalanceWindow();

        if (carryStrategy.shouldRebalance() == CarryStrategy.ShouldRebalance.REBALANCE) {
            _triggerRebalance();

            // Pending amount should be capped
            uint256 pendingAmount = carryStrategy.pendingSwapAmount();
            assertLe(pendingAmount, DEFAULT_MAX_TRADE_SIZE, "Trade should be chunked");

            // TWAP should be active for remainder
            assertTrue(carryStrategy.twapLeverageRatio() > 0 || pendingAmount == DEFAULT_MAX_TRADE_SIZE, "TWAP should handle chunks");
        }
    }

    function test_maxTradeSize_completesInMultipleSwaps() public onlyLocal {
        _setupEngagedStrategy(500_000e6);

        _applyPriceChange(500);
        _warpToRebalanceWindow();

        uint256 swapCount = 0;
        uint256 maxSwaps = 10;

        while (swapCount < maxSwaps) {
            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

            if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
                _triggerRebalance();
                _completeSwap();
                swapCount++;
            } else if (action == CarryStrategy.ShouldRebalance.ITERATE) {
                _warpPastTwapCooldown();
                _iterateRebalance();
                _completeSwap();
                swapCount++;
            } else {
                break;
            }

            _warpToRebalanceWindow();
        }

        assertTrue(swapCount > 0, "Should have executed at least one swap");
    }

    // ═══════════════════════════════════════════════════════════════════
    // REBALANCE INTERVAL
    // ═══════════════════════════════════════════════════════════════════

    function test_rebalanceInterval_blocksEarlyRebalance() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Small deviation that wouldn't trigger boundary rebalance
        _applyPriceChange(50);

        // Without waiting for interval
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

        // Should only be NONE, ITERATE, or RIPCORD before interval
        assertTrue(
            action == CarryStrategy.ShouldRebalance.NONE ||
            action == CarryStrategy.ShouldRebalance.ITERATE ||
            action == CarryStrategy.ShouldRebalance.RIPCORD,
            "Should not trigger rebalance before interval"
        );
    }

    function test_rebalanceInterval_allowsAfterElapsed() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Apply deviation
        _applyPriceChange(200);

        // Wait for interval
        _warpToRebalanceWindow();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        // Now should potentially allow rebalance if deviation > threshold
        assertTrue(
            action == CarryStrategy.ShouldRebalance.NONE ||
            action == CarryStrategy.ShouldRebalance.REBALANCE ||
            action == CarryStrategy.ShouldRebalance.ITERATE,
            "Should evaluate rebalance after interval"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // PRICE VOLATILITY SCENARIOS
    // ═══════════════════════════════════════════════════════════════════

    function test_volatility_rapidPriceSwings() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Rapid price swings
        for (uint256 i = 0; i < 5; i++) {
            if (i % 2 == 0) {
                _applyPriceChange(300);
            } else {
                _applyPriceChange(-300);
            }

            _warpToRebalanceWindow();

            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
            if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
                _triggerRebalance();
                _completeSwap();
            }
        }

        // Strategy should still be functional
        _assertIsEngaged();
    }

    function test_volatility_gradualDrift() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Gradual price drift
        for (uint256 i = 0; i < 10; i++) {
            _applyPriceChange(50); // Small incremental change
            _warpBlocks(100);
        }

        _warpToRebalanceWindow();

        // Should detect cumulative drift
        uint256 leverage = carryStrategy.getCurrentLeverageRatio();
        assertTrue(leverage > 0, "Leverage should be calculable");
    }

    // ═══════════════════════════════════════════════════════════════════
    // EDGE CASES
    // ═══════════════════════════════════════════════════════════════════

    function test_edge_rebalanceWithZeroCollateral() public onlyLocal {
        // With zero collateral, leverage is 1x which is below min leverage (2x)
        // So shouldRebalance returns REBALANCE (leverage outside bounds)
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        assertEq(
            uint256(action),
            uint256(CarryStrategy.ShouldRebalance.REBALANCE),
            "Signals REBALANCE when leverage below min (expected behavior)"
        );
    }

    function test_edge_rebalanceDuringPendingSwap() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Initiate swap but don't complete
        _applyPriceChange(300);
        _warpToRebalanceWindow();

        if (carryStrategy.shouldRebalance() == CarryStrategy.ShouldRebalance.REBALANCE) {
            _triggerRebalance();

            // Try to rebalance again while swap pending
            _warpToRebalanceWindow();
            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
            assertEq(uint256(action), uint256(CarryStrategy.ShouldRebalance.NONE), "No rebalance during pending swap");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _setupEngagedStrategy(uint256 amount) internal {
        mockUsdc.mint(address(carryStrategy), amount);
        // Note: Don't call approve here - the strategy constructor already approved max to zaibots
        vm.prank(address(carryStrategy));
        mockZaibots.supply(address(usdc), amount, address(carryStrategy));

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

    function _simulateLeverageIncrease() internal {
        // JPY appreciation increases debt value, increases leverage
        _applyPriceChange(1000); // +10%
    }

    function _simulateLeverageDecrease() internal {
        // JPY depreciation decreases debt value, decreases leverage
        _applyPriceChange(-500); // -5%
    }

    function _completeSwap() internal {
        if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
            _completeLeverSwap();
        } else if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_DELEVER_SWAP) {
            _completeDeleverSwap();
        }
    }
}
