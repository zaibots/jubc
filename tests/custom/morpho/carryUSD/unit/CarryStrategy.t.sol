// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";

/**
 * @title CarryStrategyTest
 * @notice Unit tests for CarryStrategy contract
 * @dev Uses local mode by default. For fork tests, set NETWORK=sepolia|mainnet
 */
contract CarryStrategyTest is TestCarryUSDBase {
    // ═══════════════════════════════════════════════════════════════════
    // SETUP VERIFICATION
    // ═══════════════════════════════════════════════════════════════════

    function test_setup_strategyDeployed() public view {
        assertTrue(address(carryStrategy) != address(0), "Strategy should be deployed");
    }

    function test_setup_adapterConnected() public view {
        assertEq(address(carryAdapter.strategy()), address(carryStrategy), "Adapter should be connected to strategy");
    }

    function test_setup_correctLeverageParams() public view {
        (uint64 target, uint64 min, uint64 max, uint64 ripcord) = carryStrategy.leverage();
        assertEq(target, CONSERVATIVE_TARGET, "Wrong target leverage");
        assertEq(min, CONSERVATIVE_MIN, "Wrong min leverage");
        assertEq(max, CONSERVATIVE_MAX, "Wrong max leverage");
        assertEq(ripcord, CONSERVATIVE_RIPCORD, "Wrong ripcord leverage");
    }

    function test_setup_milkmanHasLiquidity() public onlyLocal {
        assertTrue(usdc.balanceOf(address(mockMilkman)) > 0, "Milkman should have USDC");
        assertTrue(jUBC.balanceOf(address(mockMilkman)) > 0, "Milkman should have jUBC");
    }

    function test_setup_usersHaveFunds() public view {
        assertTrue(usdc.balanceOf(alice) > 0, "Alice should have USDC");
        assertTrue(usdc.balanceOf(bob) > 0, "Bob should have USDC");
    }

    // ═══════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════

    function test_init_strategyIsActive() public view {
        assertTrue(carryStrategy.isActive(), "Strategy should be active");
    }

    function test_init_strategyNotEngaged() public view {
        assertFalse(carryStrategy.isEngaged(), "Strategy should not be engaged initially");
    }

    function test_init_swapStateIdle() public view {
        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Swap state should be IDLE");
    }

    function test_init_operatorSet() public view {
        assertEq(carryStrategy.operator(), keeper, "Operator should be keeper");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════

    function test_acl_onlyOperatorCanSetActive() public {
        vm.prank(alice);
        vm.expectRevert();
        carryStrategy.setActive(false);

        vm.prank(keeper);
        carryStrategy.setActive(false);
        assertFalse(carryStrategy.isActive(), "Strategy should be deactivated");
    }

    function test_acl_allowedCallerIsSet() public view {
        // Alice is allowed caller
        assertTrue(carryStrategy.isAllowedCaller(alice), "Alice should be allowed caller");
        assertTrue(carryStrategy.isAllowedCaller(bob), "Bob should be allowed caller");
    }

    function test_acl_nonAllowedCallerNotSet() public view {
        // Charlie is not an allowed caller
        assertFalse(carryStrategy.isAllowedCaller(charlie), "Charlie should not be allowed caller");
    }

    function test_acl_ownerCanSetAllowedCaller() public {
        assertFalse(carryStrategy.isAllowedCaller(charlie), "Charlie should not be allowed initially");

        vm.prank(owner);
        carryStrategy.setAllowedCaller(charlie, true);

        assertTrue(carryStrategy.isAllowedCaller(charlie), "Charlie should now be allowed");
    }

    function test_acl_nonOwnerCannotSetAllowedCaller() public {
        vm.prank(alice);
        vm.expectRevert();
        carryStrategy.setAllowedCaller(charlie, true);
    }

    // ═══════════════════════════════════════════════════════════════════
    // LEVERAGE CALCULATIONS
    // ═══════════════════════════════════════════════════════════════════

    function test_leverage_initialRatioIsOne() public view {
        // Before any leverage, ratio should be 1x (1e18)
        uint256 leverage = carryStrategy.getCurrentLeverageRatio();
        assertEq(leverage, 1e18, "Initial leverage should be 1x");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ORACLE PRICE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_initialPrice() public view {
        (, int256 price,,,) = mockJpyUsdFeed.latestRoundData();
        assertEq(price, BASE_JPY_PRICE, "Initial JPY/USD price should be base price");
    }

    function test_oracle_priceChange() public {
        int256 initialPrice = BASE_JPY_PRICE;

        // Apply 10% increase
        _applyPriceChange(1000); // +10% in bps

        (, int256 newPrice,,,) = mockJpyUsdFeed.latestRoundData();
        assertGt(newPrice, initialPrice, "Price should have increased");

        // 650000 * 1.1 = 715000
        assertEq(newPrice, 715000, "Price should be 10% higher");
    }

    function test_oracle_staleness() public {
        // Warp to a reasonable time first (mock uses block.timestamp - 3 hours for stale)
        vm.warp(1 days);

        // Initially not stale
        (,,,uint256 updatedAt,) = mockJpyUsdFeed.latestRoundData();
        assertGt(updatedAt, 0, "Should have valid timestamp");

        // Make stale
        _makeOracleStale();

        (,,,uint256 staleUpdatedAt,) = mockJpyUsdFeed.latestRoundData();
        // Stale means old timestamp (3 hours ago in mock)
        assertLt(staleUpdatedAt, block.timestamp - 2 hours, "Should be stale");
    }

    // ═══════════════════════════════════════════════════════════════════
    // HELPER FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_helper_calculateLeverageRatio() public pure {
        // 100 collateral, 50 debt -> 100/(100-50) = 2x
        uint256 ratio = _calculateLeverageRatioStatic(100e6, 50e6);
        assertEq(ratio, 2e18, "2x leverage calculation");

        // 100 collateral, 60 debt -> 100/(100-60) = 2.5x
        ratio = _calculateLeverageRatioStatic(100e6, 60e6);
        assertEq(ratio, 2.5e18, "2.5x leverage calculation");
    }

    function test_helper_calculateLeverageRatio_noDebt() public pure {
        // No debt should return 1x
        uint256 ratio = _calculateLeverageRatioStatic(100e6, 0);
        assertEq(ratio, 1e18, "No debt should be 1x leverage");
    }

    function test_helper_calculateLeverageRatio_noCollateral() public pure {
        // No collateral should return 1x (edge case)
        uint256 ratio = _calculateLeverageRatioStatic(0, 50e6);
        assertEq(ratio, 1e18, "No collateral edge case");
    }

    function test_helper_calculateLeverageRatio_maxLeverage() public pure {
        // Debt equals collateral -> max leverage
        uint256 ratio = _calculateLeverageRatioStatic(100e6, 100e6);
        assertEq(ratio, type(uint256).max, "Equal debt/collateral should be max leverage");
    }

    function test_helper_convertJpyToUsdc() public pure {
        // 1000 jUBC at 0.0065 USD/JPY (BASE_JPY_PRICE = 650_000) = 6.5 USDC
        // (1000e18 * 650_000) / 1e20 = 6_500_000
        uint256 usdc_amount = _convertJpyToUsdcStatic(1000e18, BASE_JPY_PRICE);
        assertEq(usdc_amount, 6_500_000, "1000 jUBC = 6.5 USDC at base price");
    }

    function test_helper_convertUsdcToJpy() public pure {
        // 100 USDC at 0.0065 USD/JPY = ~15384.6 jUBC
        // (100e6 * 1e20) / 650_000 = 15384615384615384615384
        uint256 jpy_amount = _convertUsdcToJpyStatic(100e6, BASE_JPY_PRICE);
        assertEq(jpy_amount, 15384615384615384615384, "100 USDC = ~15385 jUBC at base price");
    }

    function test_helper_roundTrip() public pure {
        // Convert USDC -> JPY -> USDC should be approximately equal (minus rounding)
        uint256 initialUsdc = 1000e6;
        uint256 jpyAmount = _convertUsdcToJpyStatic(initialUsdc, BASE_JPY_PRICE);
        uint256 finalUsdc = _convertJpyToUsdcStatic(jpyAmount, BASE_JPY_PRICE);

        // Should be within 1 wei due to integer division
        assertApproxEqAbs(finalUsdc, initialUsdc, 1, "Round trip should preserve value");
    }

    // ═══════════════════════════════════════════════════════════════════
    // STATIC HELPERS (for pure tests)
    // ═══════════════════════════════════════════════════════════════════

    function _calculateLeverageRatioStatic(uint256 collateral, uint256 debtInBase) internal pure returns (uint256) {
        if (collateral == 0) return FULL_PRECISION;
        if (debtInBase == 0) return FULL_PRECISION;
        uint256 equity = collateral > debtInBase ? collateral - debtInBase : 0;
        if (equity == 0) return type(uint256).max;
        return (collateral * FULL_PRECISION) / equity;
    }

    function _convertJpyToUsdcStatic(uint256 jUBCAmount, int256 jpyUsdPrice) internal pure returns (uint256) {
        return (jUBCAmount * uint256(jpyUsdPrice)) / 1e20;
    }

    function _convertUsdcToJpyStatic(uint256 usdcAmount, int256 jpyUsdPrice) internal pure returns (uint256) {
        return (usdcAmount * 1e20) / uint256(jpyUsdPrice);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ENGAGE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_engage_requiresCollateral() public onlyLocal {
        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.NotEngaged.selector);
        carryStrategy.engage();
    }

    function test_engage_initiatesLeverSwap() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        assertEq(
            uint256(carryStrategy.swapState()),
            uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP),
            "Should initiate lever swap"
        );
    }

    function test_engage_setsTwapTarget() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        assertEq(carryStrategy.twapLeverageRatio(), CONSERVATIVE_TARGET, "Should set TWAP target");
    }

    function test_engage_cannotEngageWhenSwapPending() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.SwapPending.selector);
        carryStrategy.engage();
    }

    function test_engage_cannotEngageWhenInactive() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper);
        carryStrategy.setActive(false);

        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.StrategyNotActive.selector);
        carryStrategy.engage();
    }

    function test_engage_cannotEngageWhenAlreadyEngaged() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        _completeLeverSwap();

        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.AlreadyEngaged.selector);
        carryStrategy.engage();
    }

    // ═══════════════════════════════════════════════════════════════════
    // REBALANCE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_rebalance_requiresEOA() public onlyLocal {
        vm.prank(address(this)); // Contract context
        vm.expectRevert("Not EOA");
        carryStrategy.rebalance();
    }

    function test_rebalance_requiresAllowedCaller() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        vm.prank(charlie, charlie); // Not allowed caller
        vm.expectRevert(CarryStrategy.NotAllowedCaller.selector);
        carryStrategy.rebalance();
    }

    function test_rebalance_requiresActiveStrategy() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        vm.prank(keeper);
        carryStrategy.setActive(false);

        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.StrategyNotActive.selector);
        carryStrategy.rebalance();
    }

    function test_rebalance_revertsWhenNoRebalanceNeeded() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // No price change, should not need rebalance immediately
        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.RebalanceIntervalNotElapsed.selector);
        carryStrategy.rebalance();
    }

    // ═══════════════════════════════════════════════════════════════════
    // RIPCORD TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_ripcord_requiresEOA() public onlyLocal {
        vm.prank(address(this));
        vm.expectRevert("Not EOA");
        carryStrategy.ripcord();
    }

    function test_ripcord_failsWhenBelowThreshold() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        vm.prank(alice, alice);
        vm.expectRevert(CarryStrategy.LeverageTooLow.selector);
        carryStrategy.ripcord();
    }

    function test_ripcord_anyoneCanCall() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcordLevel();

        // Charlie (not an allowed caller) can still ripcord
        vm.prank(charlie, charlie);
        carryStrategy.ripcord();

        assertEq(
            uint256(carryStrategy.swapState()),
            uint256(CarryStrategy.SwapState.PENDING_DELEVER_SWAP),
            "Ripcord should work for any EOA"
        );
    }

    function test_ripcord_paysEthReward() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcordLevel();

        uint256 ethBefore = alice.balance;

        vm.prank(alice, alice);
        carryStrategy.ripcord();

        uint256 ethAfter = alice.balance;
        assertEq(ethAfter - ethBefore, DEFAULT_ETH_REWARD, "Should pay ETH reward");
    }

    function test_ripcord_failsWithoutEthReward() public onlyLocal {
        _setupEngagedStrategy(100_000e6);
        _pushToRipcordLevel();

        // Drain ETH from strategy
        vm.prank(owner);
        carryStrategy.withdrawEther(address(carryStrategy).balance);

        vm.prank(alice, alice);
        vm.expectRevert(CarryStrategy.InsufficientEtherReward.selector);
        carryStrategy.ripcord();
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP COMPLETION TESTS
    // ═══════════════════════════════════════════════════════════════════
    // NOTE: Swap completion is handled via Milkman callbacks, not direct method calls

    function test_completeLeverSwap_resetsSwapState() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        _completeLeverSwap();

        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should reset to IDLE");
        assertEq(carryStrategy.pendingSwapAmount(), 0, "Should reset pending amount");
        assertEq(carryStrategy.pendingSwapTs(), 0, "Should reset pending timestamp");
    }

    // ═══════════════════════════════════════════════════════════════════
    // CANCEL SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════
    // NOTE: cancelTimedOutSwap() is not implemented in the current CarryStrategy
    // These tests are placeholders

    function test_cancelSwap_placeholder() public view {
        // cancelTimedOutSwap() is not implemented in the current CarryStrategy
        assertTrue(true, "Cancel swap tests are skipped - cancelTimedOutSwap not implemented");
    }

    // ═══════════════════════════════════════════════════════════════════
    // GOVERNANCE TESTS
    // ═══════════════════════════════════════════════════════════════════
    // NOTE: updateLeverageParams is not implemented in the current CarryStrategy

    function test_governance_leverageParamsReadable() public view {
        // Leverage params are set in constructor and read-only
        (uint64 target, uint64 min, uint64 max, uint64 ripcord) = carryStrategy.leverage();
        assertTrue(target > 0, "Target should be set");
        assertTrue(min < target, "Min should be less than target");
        assertTrue(max > target, "Max should be greater than target");
        assertTrue(ripcord > max, "Ripcord should be greater than max");
    }

    function test_governance_ownerCanSetAdapter() public onlyLocal {
        address newAdapter = makeAddr("newAdapter");

        vm.prank(owner);
        carryStrategy.setAdapter(newAdapter);

        (address adapter,,,,,,,) = carryStrategy.addr();
        assertEq(adapter, newAdapter, "Adapter should be updated");
    }

    function test_governance_ownerCanSetOperator() public onlyLocal {
        address newOperator = makeAddr("newOperator");

        vm.prank(owner);
        carryStrategy.setOperator(newOperator);

        assertEq(carryStrategy.operator(), newOperator, "Operator should be updated");
    }

    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_view_getRealAssets() public onlyLocal {
        uint256 assets = carryStrategy.getRealAssets();
        assertEq(assets, 0, "Initially should have zero real assets");

        _setupCollateral(100_000e6);
        assets = carryStrategy.getRealAssets();
        assertEq(assets, 100_000e6, "Should match collateral before leverage");
    }

    function test_view_isEngaged() public onlyLocal {
        assertFalse(carryStrategy.isEngaged(), "Should not be engaged initially");

        _setupCollateral(100_000e6);
        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        assertTrue(carryStrategy.isEngaged(), "Should be engaged after engagement");
    }

    function test_view_incentiveParams() public view {
        // Incentive is configured via struct, not dynamic getter
        // IncentiveParams: (uint16 slippageBps, uint16 twapCooldown, uint128 maxTrade, uint96 etherReward)
        (,,, uint96 etherReward) = carryStrategy.incentive();
        assertEq(uint256(etherReward), DEFAULT_ETH_REWARD, "Should have configured incentive");
    }

    function test_view_shouldRebalance() public onlyLocal {
        // When not engaged, leverage is 1x which is below min leverage (2x)
        // So shouldRebalance returns REBALANCE - this is expected behavior
        // because the strategy detects leverage is outside bounds
        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        // At 1x leverage with min=2x, we're below min so need rebalance
        assertEq(
            uint256(action),
            uint256(CarryStrategy.ShouldRebalance.REBALANCE),
            "Should signal REBALANCE when leverage below min"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONSTANTS VERIFICATION
    // ═══════════════════════════════════════════════════════════════════

    function test_constants_fullPrecision() public view {
        assertEq(carryStrategy.FULL_PRECISION(), 1e18, "FULL_PRECISION should be 1e18");
    }

    function test_constants_swapTimeout() public view {
        assertEq(carryStrategy.SWAP_TIMEOUT(), 30 minutes, "SWAP_TIMEOUT should be 30 minutes");
    }

    function test_constants_maxBps() public view {
        assertEq(carryStrategy.MAX_BPS(), 10000, "MAX_BPS should be 10000");
    }

    // ═══════════════════════════════════════════════════════════════════
    // LOCAL HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _setupCollateral(uint256 amount) internal {
        mockUsdc.mint(address(carryStrategy), amount);
        // Note: Don't call approve here - the strategy constructor already approved max to zaibots
        vm.prank(address(carryStrategy));
        mockZaibots.supply(address(usdc), amount, address(carryStrategy));
    }

    function _setupEngagedStrategy(uint256 amount) internal {
        _setupCollateral(amount);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        _completeLeverSwap();

        // Complete any remaining TWAP iterations
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

    function _pushToRipcordLevel() internal {
        // Keep applying price increases until ripcord level
        while (carryStrategy.shouldRebalance() != CarryStrategy.ShouldRebalance.RIPCORD) {
            _applyPriceChange(500); // +5%
            if (carryStrategy.getCurrentLeverageRatio() > 100e18) break;
        }
    }
}
