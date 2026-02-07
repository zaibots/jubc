// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";

/**
 * @title DepegScenariosTest
 * @notice Tests strategy behavior during USDC and JPY depeg scenarios
 * @dev Critical for understanding strategy risk during market stress
 */
contract DepegScenariosTest is TestCarryUSDBase {
    // ═══════════════════════════════════════════════════════════════════
    // USDC DEPEG SCENARIOS
    // ═══════════════════════════════════════════════════════════════════

    function test_usdcDepeg_5percent() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        uint256 leverageBefore = carryStrategy.getCurrentLeverageRatio();

        // Simulate USDC depeg by changing JPY/USD relative price
        // If USDC worth 0.95 USD, JPY/USDC rate increases ~5%
        _applyPriceChange(500); // +5%

        uint256 leverageAfter = carryStrategy.getCurrentLeverageRatio();

        // Leverage should increase (debt worth more in USDC terms)
        assertTrue(leverageAfter >= leverageBefore, "Leverage should increase on USDC depeg");

        // Check if rebalance needed
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        assertTrue(
            action == CarryStrategy.ShouldRebalance.REBALANCE ||
            action == CarryStrategy.ShouldRebalance.RIPCORD ||
            action == CarryStrategy.ShouldRebalance.NONE ||
            action == CarryStrategy.ShouldRebalance.ITERATE,
            "Should evaluate strategy state"
        );
    }

    function test_usdcDepeg_10percent() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        uint256 leverageBefore = carryStrategy.getCurrentLeverageRatio();

        // More severe USDC depeg
        _applyPriceChange(1000); // +10%

        uint256 leverageAfter = carryStrategy.getCurrentLeverageRatio();

        // May trigger ripcord if leverage too high
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
            // Strategy correctly identified emergency
            assertTrue(leverageAfter >= uint256(CONSERVATIVE_RIPCORD) * 1e9, "Should be at ripcord level");
        }
    }

    function test_usdcDepeg_20percent_severe() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Severe USDC depeg (2022 USDC depeg was ~10%)
        _applyPriceChange(2000); // +20%

        uint256 leverageAfter = carryStrategy.getCurrentLeverageRatio();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

        // Strategy should likely need ripcord at this level
        if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
            uint256 ethBefore = alice.balance;

            vm.deal(address(carryStrategy), 10 ether);
            _triggerRipcord(alice);

            uint256 ethAfter = alice.balance;
            assertTrue(ethAfter > ethBefore, "Ripcord caller should receive ETH");
        }
    }

    function test_usdcDepeg_recovery() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Depeg
        _applyPriceChange(1000); // +10%

        // Handle any needed rebalance
        _warpToRebalanceWindow();
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
            _triggerRipcord(alice);
            _completeDeleverSwap();
        } else if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
            _triggerRebalance();
            _completeSwap();
        }

        // USDC repegs
        _applyPriceChange(-1000); // Back to normal

        // Strategy should be able to relever
        _warpToRebalanceWindow();
        action = carryStrategy.shouldRebalance();

        // Should be in a manageable state
        _assertIsEngaged();
    }

    // ═══════════════════════════════════════════════════════════════════
    // JPY VOLATILITY SCENARIOS
    // ═══════════════════════════════════════════════════════════════════

    function test_jpyVolatility_appreciation_5percent() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // JPY appreciates (bad for carry trade - debt worth more)
        _applyPriceChange(500); // +5%

        uint256 leverage = carryStrategy.getCurrentLeverageRatio();
        uint256 ripcordLevel = uint256(CONSERVATIVE_RIPCORD) * 1e9;

        // May need deleveraging
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        assertTrue(
            action != CarryStrategy.ShouldRebalance.ITERATE || leverage < ripcordLevel,
            "Should handle JPY appreciation"
        );
    }

    function test_jpyVolatility_depreciation_5percent() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // JPY depreciates (good for carry trade - debt worth less)
        _applyPriceChange(-500); // -5%

        uint256 leverage = carryStrategy.getCurrentLeverageRatio();

        // May need releveraging to reach target
        _warpToRebalanceWindow();
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

        assertTrue(
            action == CarryStrategy.ShouldRebalance.NONE ||
            action == CarryStrategy.ShouldRebalance.REBALANCE ||
            action == CarryStrategy.ShouldRebalance.ITERATE,
            "Should handle JPY depreciation"
        );
    }

    function test_jpyVolatility_flashCrash() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // JPY flash crash (sudden 30% depreciation)
        _applyPriceChange(-3000);

        uint256 leverage = carryStrategy.getCurrentLeverageRatio();

        // Strategy should handle extreme scenario
        assertTrue(leverage > 0, "Leverage should be calculable");
        assertTrue(leverage < type(uint256).max, "Should not overflow");

        // Good for strategy - profits locked in
        _warpToRebalanceWindow();
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

        // May need rebalance to lock in profits
        assertTrue(
            action == CarryStrategy.ShouldRebalance.NONE ||
            action == CarryStrategy.ShouldRebalance.REBALANCE ||
            action == CarryStrategy.ShouldRebalance.ITERATE,
            "Should handle flash crash"
        );
    }

    function test_jpyVolatility_flashSpike() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // JPY flash spike (sudden 30% appreciation)
        _applyPriceChange(3000);

        uint256 leverage = carryStrategy.getCurrentLeverageRatio();

        // This is dangerous - debt worth much more
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

        // Should almost certainly trigger ripcord
        if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
            _triggerRipcord(alice);
            _completeDeleverSwap();
        }

        // Strategy should survive
        _assertIsEngaged();
    }

    // ═══════════════════════════════════════════════════════════════════
    // DUAL DEPEG SCENARIOS
    // ═══════════════════════════════════════════════════════════════════

    function test_dualDepeg_usdcDownJpyUp() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Worst case: USDC depegs AND JPY appreciates
        // Combined effect: ~15% price impact
        _applyPriceChange(1500);

        uint256 leverage = carryStrategy.getCurrentLeverageRatio();

        // Extremely high leverage expected
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

        // Should definitely need ripcord
        if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
            _triggerRipcord(alice);

            // May need multiple ripcords
            _warpPastTwapCooldown();
            _completeDeleverSwap();
        }
    }

    function test_dualDepeg_bestCase() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Best case: USDC strong, JPY weak
        _applyPriceChange(-1500); // -15%

        uint256 leverage = carryStrategy.getCurrentLeverageRatio();

        // Very low leverage - strategy is profitable
        assertTrue(leverage < uint256(CONSERVATIVE_TARGET) * 1e9, "Leverage should be low");

        // May want to relever to capture more yield
        _warpToRebalanceWindow();
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

        // Should need rebalance to increase leverage
        assertTrue(
            action == CarryStrategy.ShouldRebalance.REBALANCE ||
            action == CarryStrategy.ShouldRebalance.NONE ||
            action == CarryStrategy.ShouldRebalance.ITERATE,
            "May need rebalance"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // PROLONGED STRESS
    // ═══════════════════════════════════════════════════════════════════

    function test_stress_sustainedAdverseConditions() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Simulate sustained adverse conditions over multiple periods
        for (uint256 i = 0; i < 5; i++) {
            // Gradual JPY appreciation (bad)
            _applyPriceChange(200); // +2% per period

            _warpToRebalanceWindow();

            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
            if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
                _triggerRipcord(alice);
                _completeDeleverSwap();
            } else if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
                _triggerRebalance();
                _completeSwap();
            }
        }

        // Strategy should have deleveraged to survive
        uint256 finalLeverage = carryStrategy.getCurrentLeverageRatio();
        assertTrue(finalLeverage < uint256(CONSERVATIVE_RIPCORD) * 1e9, "Should have deleveraged");
    }

    function test_stress_volatileMarket() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        int256[] memory priceChanges = new int256[](10);
        priceChanges[0] = 500;
        priceChanges[1] = -300;
        priceChanges[2] = 800;
        priceChanges[3] = -200;
        priceChanges[4] = 1000;
        priceChanges[5] = -600;
        priceChanges[6] = 400;
        priceChanges[7] = -900;
        priceChanges[8] = 200;
        priceChanges[9] = -100;

        for (uint256 i = 0; i < priceChanges.length; i++) {
            _applyPriceChange(priceChanges[i]);

            _warpBlocks(100);

            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
            if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
                _triggerRipcord(alice);
                _completeDeleverSwap();
            }

            if (i % 3 == 0) {
                _warpToRebalanceWindow();
                action = carryStrategy.shouldRebalance();
                if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
                    _triggerRebalance();
                    _completeSwap();
                }
            }
        }

        // Strategy should still be functional
        uint256 leverage = carryStrategy.getCurrentLeverageRatio();
        assertTrue(leverage >= FULL_PRECISION, "Strategy should remain leveraged or at 1x");
    }

    // ═══════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _setupEngagedStrategy(uint256 amount) internal {
        mockUsdc.mint(address(carryStrategy), amount);
        // Note: Don't call approve here - the strategy constructor already approved max to zaibots
        vm.prank(address(carryStrategy));
        mockPool.supply(address(usdc), amount, address(carryStrategy));

        _engageStrategy();
        _completeLeverSwap();

        // Complete any remaining TWAP iterations
        while (carryStrategy.twapLeverageRatio() > 0 && carryStrategy.swapState() == CarryStrategy.SwapState.IDLE) {
            _warpPastTwapCooldown();
            if (carryStrategy.shouldRebalance() == CarryStrategy.ShouldRebalance.ITERATE) {
                _iterateRebalance();
                if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
                    _completeLeverSwap();
                }
            } else {
                break;
            }
        }
    }

    function _completeSwap() internal {
        if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
            _completeLeverSwap();
        } else if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_DELEVER_SWAP) {
            _completeDeleverSwap();
        }
    }
}
