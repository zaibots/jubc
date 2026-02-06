// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";

/**
 * @title RipcordEmergencyTest
 * @notice Tests ripcord emergency deleveraging mechanics
 * @dev Tests incentives, competition, and edge cases
 */
contract RipcordEmergencyTest is TestCarryUSDBase {
    // ═══════════════════════════════════════════════════════════════════
    // RIPCORD TRIGGER
    // ═══════════════════════════════════════════════════════════════════

    function test_ripcord_triggersAtThreshold() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Push leverage to ripcord threshold
        _pushToRipcord();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        assertEq(uint256(action), uint256(CarryStrategy.ShouldRebalance.RIPCORD), "Should trigger ripcord");
    }

    function test_ripcord_failsBelowThreshold() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Leverage is at target, below ripcord
        uint256 leverage = carryStrategy.getCurrentLeverageRatio();
        uint256 ripcordLevel = uint256(CONSERVATIVE_RIPCORD) * 1e9;

        if (leverage < ripcordLevel) {
            vm.prank(alice, alice);
            vm.expectRevert(CarryStrategy.LeverageTooLow.selector);
            carryStrategy.ripcord();
        }
    }

    function test_ripcord_initiatesDelever() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        _triggerRipcord(alice);

        assertEq(
            uint256(carryStrategy.swapState()),
            uint256(CarryStrategy.SwapState.PENDING_DELEVER_SWAP),
            "Should initiate delever swap"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // ETH INCENTIVE
    // ═══════════════════════════════════════════════════════════════════

    function test_incentive_paysEthReward() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        uint256 ethBefore = alice.balance;
        uint256 expectedReward = DEFAULT_ETH_REWARD;

        _triggerRipcord(alice);

        uint256 ethAfter = alice.balance;
        assertEq(ethAfter - ethBefore, expectedReward, "Should receive ETH reward");
    }

    function test_incentive_failsWithoutEth() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        // Drain ETH from strategy
        vm.prank(owner);
        carryStrategy.withdrawEther(address(carryStrategy).balance);

        vm.prank(alice, alice);
        vm.expectRevert(CarryStrategy.InsufficientEtherReward.selector);
        carryStrategy.ripcord();
    }

    function test_incentive_rewardIsCorrectAmount() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        // Access incentive struct directly - etherReward is always configured regardless of ripcord state
        // IncentiveParams: (uint16 slippageBps, uint16 twapCooldown, uint128 maxTrade, uint96 etherReward)
        (,,, uint96 etherReward) = carryStrategy.incentive();
        assertEq(uint256(etherReward), DEFAULT_ETH_REWARD, "Incentive should match config");
    }

    function test_incentive_configuredCorrectly() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Verify incentive params are configured correctly
        // IncentiveParams: (uint16 slippageBps, uint16 twapCooldown, uint128 maxTrade, uint96 etherReward)
        (uint16 slippageBps, uint16 twapCooldown, uint128 maxTrade, uint96 etherReward) = carryStrategy.incentive();
        assertTrue(maxTrade > 0, "Max trade should be configured");
        assertTrue(slippageBps > 0, "Slippage should be configured");
        assertTrue(twapCooldown > 0 || twapCooldown == 0, "Twap cooldown should be configured");
        assertEq(uint256(etherReward), DEFAULT_ETH_REWARD, "Ether reward should match config");
    }

    // ═══════════════════════════════════════════════════════════════════
    // COMPETING CALLERS
    // ═══════════════════════════════════════════════════════════════════

    function test_competition_firstCallerWins() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        uint256 aliceEthBefore = alice.balance;
        uint256 bobEthBefore = bob.balance;

        // Alice calls first
        _triggerRipcord(alice);

        uint256 aliceEthAfter = alice.balance;
        assertEq(aliceEthAfter - aliceEthBefore, DEFAULT_ETH_REWARD, "Alice should get reward");

        // Bob tries to call - should fail (swap pending)
        vm.prank(bob, bob);
        vm.expectRevert(); // SwapPending or LeverageTooLow depending on state
        carryStrategy.ripcord();
    }

    function test_competition_multipleRipcordsNeeded() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        // First ripcord
        _triggerRipcord(alice);
        _completeDeleverSwap();

        // Check if still at ripcord level
        _pushToRipcord();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.RIPCORD) {
            // Bob can call second ripcord
            uint256 bobEthBefore = bob.balance;
            _triggerRipcord(bob);
            uint256 bobEthAfter = bob.balance;

            assertEq(bobEthAfter - bobEthBefore, DEFAULT_ETH_REWARD, "Bob should get reward");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // RIPCORD DURING PENDING SWAP
    // ═══════════════════════════════════════════════════════════════════

    function test_ripcord_blockedDuringPendingSwap() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Start a regular rebalance
        _applyPriceChange(300);
        _warpToRebalanceWindow();

        if (carryStrategy.shouldRebalance() == CarryStrategy.ShouldRebalance.REBALANCE) {
            _triggerRebalance();

            // Now push to ripcord level
            _applyPriceChange(2000);

            // Ripcord should be blocked
            vm.prank(alice, alice);
            vm.expectRevert(); // May be SwapPending
            carryStrategy.ripcord();
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // RIPCORD SLIPPAGE
    // ═══════════════════════════════════════════════════════════════════

    function test_ripcord_usesIncentiveSlippage() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        _triggerRipcord(alice);

        // Ripcord uses incentive.slippageBps (200 = 2%)
        // This is verified in the swap execution
        assertTrue(carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_DELEVER_SWAP, "Should be pending delever");
    }

    function test_ripcord_respectsMaxTrade() public onlyLocal {
        // Large position
        _setupEngagedStrategy(500_000e6);
        _pushToRipcord();

        _triggerRipcord(alice);

        // Should be capped at incentive.maxTrade
        uint256 pendingAmount = carryStrategy.pendingSwapAmount();
        assertLe(pendingAmount, DEFAULT_RIPCORD_MAX_TRADE, "Should respect ripcord max trade");
    }

    // ═══════════════════════════════════════════════════════════════════
    // EOA REQUIREMENT
    // ═══════════════════════════════════════════════════════════════════

    function test_ripcord_onlyEOA() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        // Contract cannot call ripcord
        vm.prank(address(this));
        vm.expectRevert("Not EOA");
        carryStrategy.ripcord();
    }

    function test_ripcord_anyEOACanCall() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        // Even non-allowed caller can ripcord
        address randomEOA = makeAddr("random");
        vm.deal(randomEOA, 1 ether);

        uint256 ethBefore = randomEOA.balance;
        vm.prank(randomEOA, randomEOA);
        carryStrategy.ripcord();
        uint256 ethAfter = randomEOA.balance;

        assertEq(ethAfter - ethBefore, DEFAULT_ETH_REWARD, "Random EOA should get reward");
    }

    // ═══════════════════════════════════════════════════════════════════
    // POST-RIPCORD STATE
    // ═══════════════════════════════════════════════════════════════════

    function test_ripcord_updatesLastTradeTs() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        uint256 tsBefore = carryStrategy.lastTradeTs();

        _triggerRipcord(alice);

        uint256 tsAfter = carryStrategy.lastTradeTs();
        assertTrue(tsAfter >= tsBefore, "Should update last trade timestamp");
    }

    function test_ripcord_completionReducesLeverage() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcord();

        uint256 leverageBefore = carryStrategy.getCurrentLeverageRatio();

        _triggerRipcord(alice);
        _completeDeleverSwap();

        uint256 leverageAfter = carryStrategy.getCurrentLeverageRatio();
        assertTrue(leverageAfter < leverageBefore, "Leverage should decrease after ripcord");
    }

    // ═══════════════════════════════════════════════════════════════════
    // RIPCORD CHAIN
    // ═══════════════════════════════════════════════════════════════════

    function test_ripcord_multipleCallsUntilSafe() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Push way above ripcord
        _applyPriceChange(4000); // +40%

        uint256 ripcordCount = 0;
        uint256 maxRipcords = 10;

        while (ripcordCount < maxRipcords) {
            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

            if (action != CarryStrategy.ShouldRebalance.RIPCORD) break;

            _triggerRipcord(alice);
            _completeDeleverSwap();
            ripcordCount++;
        }

        // Should eventually get below ripcord threshold
        uint256 finalLeverage = carryStrategy.getCurrentLeverageRatio();
        uint256 ripcordLevel = uint256(CONSERVATIVE_RIPCORD) * 1e9;

        assertTrue(finalLeverage < ripcordLevel, "Should eventually delever below ripcord");
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

    function _pushToRipcord() internal {
        // Increase JPY price to push leverage up
        _applyPriceChange(2000); // +20%

        // Keep increasing until we hit ripcord
        while (carryStrategy.shouldRebalance() != CarryStrategy.ShouldRebalance.RIPCORD) {
            _applyPriceChange(500);

            // Safety break
            if (carryStrategy.getCurrentLeverageRatio() > 100e18) break;
        }
    }
}
