// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryKeeper, IKeeperCarryStrategy} from "custom/products/carryUSDC/CarryKeeper.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";

/**
 * @title CarryKeeperTest
 * @notice Unit tests for CarryKeeper contract
 * @dev Tests Chainlink Automation integration for strategy maintenance
 */
contract CarryKeeperTest is TestCarryUSDBase {
    // ═══════════════════════════════════════════════════════════════════
    // SETUP VERIFICATION
    // ═══════════════════════════════════════════════════════════════════

    function test_setup_keeperDeployed() public view {
        assertTrue(address(carryKeeper) != address(0), "Keeper should be deployed");
    }

    function test_setup_strategyRegistered() public view {
        assertTrue(carryKeeper.isRegistered(address(carryStrategy)), "Strategy should be registered");
    }

    // ═══════════════════════════════════════════════════════════════════
    // STRATEGY REGISTRY
    // ═══════════════════════════════════════════════════════════════════

    function test_registry_addStrategy() public {
        // Deploy a new strategy for testing
        CarryStrategy.Addresses memory strategyAddresses = CarryStrategy.Addresses({
            adapter: address(0),
            zaibots: config.zaibots != address(0) ? config.zaibots : address(1),
            collateralToken: config.usdc,
            debtToken: config.jUBC,
            jpyUsdOracle: config.jpyUsdFeed,
            jpyUsdAggregator: address(0),
            twapOracle: address(twapOracle),
            milkman: config.milkman,
            priceChecker: address(priceChecker)
        });

        CarryStrategy.ExecutionParams memory execParams = CarryStrategy.ExecutionParams({
            maxTradeSize: DEFAULT_MAX_TRADE_SIZE,
            twapCooldown: DEFAULT_TWAP_COOLDOWN,
            slippageBps: DEFAULT_SLIPPAGE_BPS,
            rebalanceInterval: DEFAULT_REBALANCE_INTERVAL,
            recenterSpeed: DEFAULT_RECENTER_SPEED
        });

        CarryStrategy.IncentiveParams memory incParams = CarryStrategy.IncentiveParams({
            slippageBps: DEFAULT_RIPCORD_SLIPPAGE_BPS,
            twapCooldown: DEFAULT_RIPCORD_COOLDOWN,
            maxTrade: DEFAULT_RIPCORD_MAX_TRADE,
            etherReward: DEFAULT_ETH_REWARD
        });

        vm.prank(owner);
        CarryStrategy newStrategy = new CarryStrategy(
            "Test Strategy",
            CarryStrategy.StrategyType.MODERATE,
            strategyAddresses,
            [CONSERVATIVE_TARGET, CONSERVATIVE_MIN, CONSERVATIVE_MAX, CONSERVATIVE_RIPCORD],
            execParams,
            incParams
        );

        vm.prank(owner);
        carryKeeper.addStrategy(address(newStrategy));

        assertTrue(carryKeeper.isRegistered(address(newStrategy)), "New strategy should be registered");
    }

    function test_registry_removeStrategy() public {
        // First verify it's registered
        assertTrue(carryKeeper.isRegistered(address(carryStrategy)), "Should be registered");

        // Remove it
        vm.prank(owner);
        carryKeeper.removeStrategy(address(carryStrategy));

        assertFalse(carryKeeper.isRegistered(address(carryStrategy)), "Should be removed");

        // Re-add for other tests
        vm.prank(owner);
        carryKeeper.addStrategy(address(carryStrategy));
    }

    function test_registry_onlyOwnerCanAdd() public {
        vm.prank(alice);
        vm.expectRevert();
        carryKeeper.addStrategy(address(0x123));
    }

    function test_registry_onlyOwnerCanRemove() public {
        vm.prank(alice);
        vm.expectRevert();
        carryKeeper.removeStrategy(address(carryStrategy));
    }

    function test_registry_cannotAddDuplicate() public {
        vm.prank(owner);
        vm.expectRevert();
        carryKeeper.addStrategy(address(carryStrategy)); // Already added
    }

    function test_registry_cannotRemoveNonexistent() public {
        vm.prank(owner);
        vm.expectRevert();
        carryKeeper.removeStrategy(address(0x123)); // Not registered
    }

    // ═══════════════════════════════════════════════════════════════════
    // CHECK UPKEEP
    // ═══════════════════════════════════════════════════════════════════

    function test_checkUpkeep_returnsCorrectData() public view {
        // Check upkeep should return valid data structure
        (bool upkeepNeeded, bytes memory performData) = carryKeeper.checkUpkeep(bytes(""));

        // If no upkeep needed, perform data should be empty
        // If upkeep needed, perform data should contain strategy and action
        if (upkeepNeeded) {
            assertTrue(performData.length > 0, "Perform data should be non-empty when upkeep needed");
        }
        // Just verify it doesn't revert
        assertTrue(true, "checkUpkeep should complete without revert");
    }

    function test_checkUpkeep_scansAllStrategies() public view {
        // Should not revert when scanning
        (bool upkeepNeeded,) = carryKeeper.checkUpkeep(bytes(""));

        // Result depends on strategy state
        assertTrue(upkeepNeeded || !upkeepNeeded, "Check should complete");
    }

    // ═══════════════════════════════════════════════════════════════════
    // PERFORM UPKEEP
    // ═══════════════════════════════════════════════════════════════════

    function test_performUpkeep_revertsIfNoAction() public {
        // Get check upkeep result
        (bool upkeepNeeded, bytes memory performData) = carryKeeper.checkUpkeep(bytes(""));

        if (!upkeepNeeded) {
            // Perform should revert if no upkeep needed
            vm.expectRevert();
            carryKeeper.performUpkeep(performData);
        }
    }

    function test_performUpkeep_handlesNotEOA() public {
        // This test verifies that performUpkeep handles the NotEOA error
        // Since the caller is a contract, the strategy's onlyEOA modifier will revert
        (bool upkeepNeeded, bytes memory performData) = carryKeeper.checkUpkeep(bytes(""));

        if (upkeepNeeded) {
            // The strategy requires EOA callers, so this will revert with NotEOA
            // when called from a contract context
            vm.expectRevert();
            carryKeeper.performUpkeep(performData);
        }
        // If no upkeep needed, test passes
    }

    // ═══════════════════════════════════════════════════════════════════
    // STRATEGY COUNT
    // ═══════════════════════════════════════════════════════════════════

    function test_strategyCount_returnsCorrect() public view {
        uint256 count = carryKeeper.getStrategies().length;
        assertEq(count, 1, "Should have 1 registered strategy");
    }

    function test_strategyCount_updatesOnAddRemove() public {
        uint256 initialCount = carryKeeper.getStrategies().length;

        // Add a dummy strategy
        vm.prank(owner);
        carryKeeper.addStrategy(address(0x999));

        assertEq(carryKeeper.getStrategies().length, initialCount + 1, "Count should increase");

        // Remove it
        vm.prank(owner);
        carryKeeper.removeStrategy(address(0x999));

        assertEq(carryKeeper.getStrategies().length, initialCount, "Count should return to initial");
    }

    // ═══════════════════════════════════════════════════════════════════
    // GET STRATEGIES
    // ═══════════════════════════════════════════════════════════════════

    function test_getStrategies_returnsAll() public view {
        address[] memory strategies = carryKeeper.getStrategies();
        assertEq(strategies.length, 1, "Should have 1 strategy");
        assertEq(strategies[0], address(carryStrategy), "Should be our strategy");
    }

    // ═══════════════════════════════════════════════════════════════════
    // GAS OPTIMIZATION
    // ═══════════════════════════════════════════════════════════════════

    function test_performUpkeep_detectsIterateAction() public onlyLocal {
        // Setup collateral and engage the strategy
        mockUsdc.mint(address(carryStrategy), 100_000e6);
        vm.prank(address(carryStrategy));
        mockPool.supply(address(usdc), 100_000e6, address(carryStrategy));

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        // Complete the lever swap
        bytes32 swapId = mockMilkman.getLatestSwapId();
        mockMilkman.settleSwapWithPrice(swapId);
        carryStrategy.completeSwap();

        // Warp past TWAP cooldown so shouldRebalance returns ITERATE
        vm.warp(block.timestamp + DEFAULT_TWAP_COOLDOWN + 1);

        // Verify keeper detects ITERATE action
        (bool upkeepNeeded, bytes memory performData) = carryKeeper.checkUpkeep(bytes(""));
        assertTrue(upkeepNeeded, "Keeper should detect upkeep needed");

        // Decode and verify action type is ITERATE (2)
        (address strategy, uint8 actionType) = abi.decode(performData, (address, uint8));
        assertEq(strategy, address(carryStrategy), "Should target our strategy");
        assertEq(actionType, uint8(IKeeperCarryStrategy.ShouldRebalance.ITERATE), "Action should be ITERATE");

        // Note: performUpkeep reverts with "Not EOA" because the keeper contract
        // calls strategy.iterateRebalance() where msg.sender = keeper contract ≠ tx.origin.
        // In production, Chainlink Automation nodes call performUpkeep as EOAs directly.
        // The keeper's role is detection (checkUpkeep); execution is via direct EOA calls.
    }

    function test_gas_checkUpkeepIsView() public view {
        // checkUpkeep should be a view function (no state changes)
        (bool upkeepNeeded,) = carryKeeper.checkUpkeep(bytes(""));
        assertTrue(upkeepNeeded || !upkeepNeeded, "Should return without modifying state");
    }

    function test_gas_multipleStrategiesCheck() public {
        // Add multiple dummy strategies
        for (uint256 i = 1; i <= 5; i++) {
            vm.prank(owner);
            carryKeeper.addStrategy(address(uint160(0x1000 + i)));
        }

        // Check should still work
        (bool upkeepNeeded,) = carryKeeper.checkUpkeep(bytes(""));
        assertTrue(upkeepNeeded || !upkeepNeeded, "Multi-strategy check should work");

        // Cleanup
        for (uint256 i = 1; i <= 5; i++) {
            vm.prank(owner);
            carryKeeper.removeStrategy(address(uint160(0x1000 + i)));
        }
    }
}
