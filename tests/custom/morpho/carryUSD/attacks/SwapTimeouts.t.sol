// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";

/**
 * @title SwapTimeoutsTest
 * @notice Tests swap timeout mechanics and edge cases
 */
contract SwapTimeoutsTest is TestCarryUSDBase {

    function _setupPendingSwap() internal {
        mockUsdc.mint(address(carryStrategy), 100_000e6);
        vm.prank(address(carryStrategy));
        mockPool.supply(address(usdc), 100_000e6, address(carryStrategy));
        vm.prank(keeper, keeper);
        carryStrategy.engage();
    }

    function test_swapTimeout_cancelAfterExpiry() public onlyLocal {
        _setupPendingSwap();
        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP));

        _warpPastSwapTimeout();

        vm.prank(keeper, keeper);
        carryStrategy.cancelTimedOutSwap();

        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should be IDLE after cancel");
    }

    function test_swapTimeout_cannotCancelBeforeExpiry() public onlyLocal {
        _setupPendingSwap();

        // Try to cancel immediately (before timeout)
        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.SwapNotTimedOut.selector);
        carryStrategy.cancelTimedOutSwap();
    }

    function test_swapTimeout_strategyResumesAfterCancel() public onlyLocal {
        _setupPendingSwap();

        _warpPastSwapTimeout();

        vm.prank(keeper, keeper);
        carryStrategy.cancelTimedOutSwap();

        // Strategy should be able to engage again (swap state is IDLE)
        // The strategy still has collateral in zaibots, and leverage is ~1x since the swap never completed
        uint256 currentLev = carryStrategy.getCurrentLeverageRatio();
        // After cancel, we may have leftover debt from the failed borrow+swap
        // The key assertion is that the strategy can be interacted with again
        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should be IDLE");

        // Verify no swap is blocking further operations by checking shouldRebalance doesn't return NONE
        // (it would if swapState != IDLE)
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        assertTrue(uint256(action) != 0, "Should need some rebalance action after cancel");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ATTACK SCENARIOS (Phase 3 v2)
    // ═══════════════════════════════════════════════════════════════════

    function test_attack_unsolicitedTokenTransfer_reverts() public onlyLocal {
        _setupPendingSwap();

        // Attacker sends 100 USDC to the strategy directly
        mockUsdc.mint(address(carryStrategy), 100e6);

        // completeSwap should revert because 100 USDC < expected output
        vm.expectRevert(CarryStrategy.SwapOutputTooLow.selector);
        carryStrategy.completeSwap();
    }

    function test_attack_cannotCompleteWithDustAmount() public onlyLocal {
        _setupPendingSwap();

        // Send 1 wei of USDC
        mockUsdc.mint(address(carryStrategy), 1);

        vm.expectRevert(CarryStrategy.SwapOutputTooLow.selector);
        carryStrategy.completeSwap();
    }

    function test_attack_legitimateSwapStillWorks() public onlyLocal {
        _setupPendingSwap();

        // Normal Milkman settlement
        bytes32 swapId = mockMilkman.getLatestSwapId();
        mockMilkman.settleSwapWithPrice(swapId);

        // Charlie (unauthorized) calls completeSwap — permissionless is fine for legit swaps
        vm.prank(charlie);
        carryStrategy.completeSwap();

        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should complete");
    }
}
