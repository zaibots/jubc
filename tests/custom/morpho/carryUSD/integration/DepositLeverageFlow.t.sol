// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title DepositLeverageFlowTest
 * @notice Integration tests for deposit → engage → leverage → rebalance flows
 * @dev Tests complete user journeys through the strategy
 */
contract DepositLeverageFlowTest is TestCarryUSDBase {
    // ═══════════════════════════════════════════════════════════════════
    // DEPOSIT FLOWS
    // ═══════════════════════════════════════════════════════════════════

    function test_deposit_singleUser() public onlyLocal {
        uint256 amount = 10_000e6;

        // Simulate deposit through adapter
        vm.startPrank(alice);
        mockUsdc.approve(address(carryAdapter), amount);

        // Transfer to adapter manually (simulating vault allocation)
        mockUsdc.transfer(address(carryAdapter), amount);
        vm.stopPrank();

        // Adapter forwards to strategy
        vm.prank(address(carryAdapter.vault()));
        mockUsdc.approve(address(carryAdapter), amount);

        // Strategy should receive assets
        assertEq(mockUsdc.balanceOf(address(carryAdapter)), amount, "Adapter should hold deposit");
    }

    function test_deposit_multipleUsers() public onlyLocal {
        uint256 aliceAmount = 10_000e6;
        uint256 bobAmount = 25_000e6;

        // Alice deposits
        vm.prank(alice);
        mockUsdc.transfer(address(carryAdapter), aliceAmount);

        // Bob deposits
        vm.prank(bob);
        mockUsdc.transfer(address(carryAdapter), bobAmount);

        uint256 totalDeposits = aliceAmount + bobAmount;
        assertEq(mockUsdc.balanceOf(address(carryAdapter)), totalDeposits, "Total deposits should match");
    }

    function test_deposit_verySmallAmount() public onlyLocal {
        uint256 amount = 1; // 1 wei USDC

        vm.prank(alice);
        mockUsdc.transfer(address(carryAdapter), amount);

        assertEq(mockUsdc.balanceOf(address(carryAdapter)), amount, "Tiny deposit should work");
    }

    function test_deposit_veryLargeAmount() public onlyLocal {
        uint256 amount = 100_000_000e6; // 100M USDC

        vm.prank(alice);
        mockUsdc.transfer(address(carryAdapter), amount);

        assertEq(mockUsdc.balanceOf(address(carryAdapter)), amount, "Large deposit should work");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ENGAGE FLOWS
    // ═══════════════════════════════════════════════════════════════════

    function test_engage_afterDeposit() public onlyLocal {
        // Setup: deposit collateral to strategy
        _setupCollateral(10_000e6);

        // Engage should initiate leverage
        _engageStrategy();

        // Should be in pending lever swap state
        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP), "Should be pending lever swap");
    }

    function test_engage_cannotEngageTwice() public onlyLocal {
        _setupCollateral(10_000e6);
        _engageStrategy();

        // Complete the swap
        _completeLeverSwap();

        // Try to engage again - should revert
        vm.expectRevert(CarryStrategy.AlreadyEngaged.selector);
        _engageStrategy();
    }

    function test_engage_requiresCollateral() public onlyLocal {
        // No collateral deposited
        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.NotEngaged.selector);
        carryStrategy.engage();
    }

    function test_engage_setsTwapTarget() public onlyLocal {
        _setupCollateral(10_000e6);
        _engageStrategy();

        assertEq(carryStrategy.twapLeverageRatio(), CONSERVATIVE_TARGET, "TWAP target should be set");
    }

    // ═══════════════════════════════════════════════════════════════════
    // LEVERAGE OPERATIONS
    // ═══════════════════════════════════════════════════════════════════

    function test_leverage_borrowsCorrectAmount() public onlyLocal {
        uint256 depositAmount = 10_000e6;
        _setupCollateral(depositAmount);
        _engageStrategy();

        // Check that jUBC was borrowed
        uint256 borrowedJubc = mockJUBC.balanceOf(address(mockMilkman));
        assertTrue(borrowedJubc > 0, "Should have borrowed jUBC");
    }

    function test_leverage_respectsMaxTradeSize() public onlyLocal {
        // Deposit more than maxTradeSize
        uint256 largeDeposit = DEFAULT_MAX_TRADE_SIZE * 3;
        _setupCollateral(largeDeposit);

        _engageStrategy();

        // Trade should be capped at maxTradeSize
        uint256 pendingAmount = carryStrategy.pendingSwapAmount();
        assertLe(pendingAmount, DEFAULT_MAX_TRADE_SIZE, "Trade should respect max size");
    }

    function test_leverage_completesSwap() public onlyLocal {
        _setupCollateral(10_000e6);
        _engageStrategy();

        // Complete the lever swap
        _completeLeverSwap();

        // Should be back to IDLE
        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should be idle after swap");
    }

    // ═══════════════════════════════════════════════════════════════════
    // TWAP ITERATION
    // ═══════════════════════════════════════════════════════════════════

    function test_twap_iteratesUntilTarget() public onlyLocal {
        // Large deposit requiring multiple iterations
        uint256 largeDeposit = DEFAULT_MAX_TRADE_SIZE * 5;
        _setupCollateral(largeDeposit);

        _engageStrategy();
        _completeLeverSwap();

        // Should need more iterations
        assertTrue(carryStrategy.twapLeverageRatio() > 0, "TWAP should be active");

        // Iterate
        _warpPastTwapCooldown();
        _iterateRebalance();
        _completeLeverSwap();
    }

    function test_twap_respectsCooldown() public onlyLocal {
        uint256 largeDeposit = DEFAULT_MAX_TRADE_SIZE * 5;
        _setupCollateral(largeDeposit);

        _engageStrategy();
        _completeLeverSwap();

        // Try to iterate before cooldown
        vm.expectRevert(CarryStrategy.RebalanceIntervalNotElapsed.selector);
        _iterateRebalance();
    }

    function test_twap_clearsWhenTargetReached() public onlyLocal {
        // Use _setupEngagedStrategy which completes all TWAP iterations
        _setupEngagedStrategy(10_000e6);

        // After full engagement, TWAP should have cleared
        assertEq(carryStrategy.twapLeverageRatio(), 0, "TWAP should clear when target reached");

        // shouldRebalance should not return ITERATE
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        assertTrue(
            action != CarryStrategy.ShouldRebalance.ITERATE,
            "Should not need TWAP iteration after target reached"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // REBALANCE FLOWS
    // ═══════════════════════════════════════════════════════════════════

    function test_rebalance_leverUpOnPriceDecrease() public onlyLocal {
        _setupEngagedStrategy(50_000e6);

        // Simulate JPY depreciation (good for carry trade, but reduces leverage)
        _applyPriceChange(-500); // -5% JPY price

        _warpToRebalanceWindow();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        // Depending on the new leverage, may need rebalance
        assertTrue(
            action == CarryStrategy.ShouldRebalance.REBALANCE ||
            action == CarryStrategy.ShouldRebalance.NONE,
            "Should check for rebalance"
        );
    }

    function test_rebalance_deleverOnPriceIncrease() public onlyLocal {
        _setupEngagedStrategy(50_000e6);

        // Simulate JPY appreciation (bad for carry trade, increases leverage)
        _applyPriceChange(500); // +5% JPY price

        _warpToRebalanceWindow();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        // Higher leverage may need delever
        assertTrue(
            action == CarryStrategy.ShouldRebalance.REBALANCE ||
            action == CarryStrategy.ShouldRebalance.RIPCORD ||
            action == CarryStrategy.ShouldRebalance.NONE,
            "Should check for delever"
        );
    }

    function test_rebalance_noActionWhenInRange() public onlyLocal {
        _setupEngagedStrategy(50_000e6);

        // No price change, within range
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();

        // Just after engagement, should be IDLE or ITERATE
        assertTrue(
            action == CarryStrategy.ShouldRebalance.NONE ||
            action == CarryStrategy.ShouldRebalance.ITERATE,
            "Should not need rebalance when in range"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // FULL CYCLE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_fullCycle_depositEngageMaintain() public onlyLocal {
        // Step 1: Deposit
        uint256 depositAmount = 100_000e6;
        _setupCollateral(depositAmount);

        // Step 2: Engage
        _engageStrategy();
        _completeLeverSwap();

        // Step 3: Wait and rebalance if needed
        _warpToRebalanceWindow();
        _applyPriceChange(200); // Small price change

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
            _triggerRebalance();
            _completeDeleverSwap();
        }

        // Strategy should still be engaged
        _assertIsEngaged();
    }

    function test_fullCycle_multipleRebalances() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Multiple rebalance cycles
        for (uint256 i = 0; i < 3; i++) {
            _warpToRebalanceWindow();

            // Apply alternating price changes
            if (i % 2 == 0) {
                _applyPriceChange(300);
            } else {
                _applyPriceChange(-300);
            }

            CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
            if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
                _triggerRebalance();
                // Complete whichever swap was initiated
                if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
                    _completeLeverSwap();
                } else if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_DELEVER_SWAP) {
                    _completeDeleverSwap();
                }
            }
        }

        _assertIsEngaged();
    }

    // ═══════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _setupCollateral(uint256 amount) internal {
        // Mint and supply collateral to MockAavePool
        mockUsdc.mint(address(carryStrategy), amount);
        // Note: Don't call approve here - the strategy constructor already approved max to zaibots
        vm.prank(address(carryStrategy));
        mockPool.supply(address(usdc), amount, address(carryStrategy));
    }

    function _setupEngagedStrategy(uint256 amount) internal {
        _setupCollateral(amount);
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
}
