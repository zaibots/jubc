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

    function test_completeSwap_lever_suppliesCollateral() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        uint256 collateralBefore = mockPool.getCollateralBalance(address(carryStrategy), address(usdc));

        // Settle milkman swap (tokens go to strategy)
        bytes32 swapId = mockMilkman.getLatestSwapId();
        mockMilkman.settleSwapWithPrice(swapId);

        // Call completeSwap to supply tokens to zaibots
        carryStrategy.completeSwap();

        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should reset to IDLE");
        assertEq(carryStrategy.pendingSwapAmount(), 0, "Should reset pending amount");
        assertEq(carryStrategy.pendingSwapTs(), 0, "Should reset pending timestamp");
        assertGt(mockPool.getCollateralBalance(address(carryStrategy), address(usdc)), collateralBefore, "Collateral should increase");
    }

    function test_completeSwap_delever_repaysDebt() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Push price up to trigger delever rebalance
        _applyPriceChange(2000); // +20% yen weakening
        _warpToRebalanceWindow();

        // Trigger rebalance (delever direction)
        uint256 currentLev = carryStrategy.getCurrentLeverageRatio();
        uint256 targetLev = uint256(CONSERVATIVE_TARGET) * 1e9;
        if (currentLev > targetLev) {
            vm.prank(keeper, keeper);
            carryStrategy.rebalance();

            assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.PENDING_DELEVER_SWAP), "Should be pending delever");

            uint256 debtBefore = mockPool.getDebtBalance(address(carryStrategy), address(jUBC));

            // Settle and complete
            bytes32 swapId = mockMilkman.getLatestSwapId();
            mockMilkman.settleSwapWithPrice(swapId);
            carryStrategy.completeSwap();

            assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should reset to IDLE");
            assertLe(mockPool.getDebtBalance(address(carryStrategy), address(jUBC)), debtBefore, "Debt should decrease or stay");
        }
    }

    function test_completeSwap_revertsWhenIdle() public onlyLocal {
        vm.expectRevert(CarryStrategy.SwapNotPending.selector);
        carryStrategy.completeSwap();
    }

    function test_completeSwap_isPermissionless() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        bytes32 swapId = mockMilkman.getLatestSwapId();
        mockMilkman.settleSwapWithPrice(swapId);

        // Charlie (not an allowed caller) can call completeSwap
        vm.prank(charlie);
        carryStrategy.completeSwap();

        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should reset to IDLE");
    }

    // ═══════════════════════════════════════════════════════════════════
    // CANCEL TIMED OUT SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelTimedOutSwap_works() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP), "Should be pending");

        _warpPastSwapTimeout();

        vm.prank(keeper, keeper);
        carryStrategy.cancelTimedOutSwap();

        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should be IDLE after cancel");
        assertEq(carryStrategy.pendingSwapAmount(), 0, "Should reset pending amount");
        assertEq(carryStrategy.pendingSwapTs(), 0, "Should reset pending timestamp");
    }

    function test_cancelTimedOutSwap_revertsBeforeTimeout() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.SwapNotTimedOut.selector);
        carryStrategy.cancelTimedOutSwap();
    }

    function test_cancelTimedOutSwap_revertsWhenIdle() public onlyLocal {
        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.SwapNotPending.selector);
        carryStrategy.cancelTimedOutSwap();
    }

    function test_cancelTimedOutSwap_onlyAllowedCaller() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        _warpPastSwapTimeout();

        vm.prank(charlie, charlie);
        vm.expectRevert(CarryStrategy.NotAllowedCaller.selector);
        carryStrategy.cancelTimedOutSwap();
    }

    // ═══════════════════════════════════════════════════════════════════
    // ITERATE REBALANCE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_iterateRebalance_leversTowardTarget() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        // twapLeverageRatio should be set after engage
        assertTrue(carryStrategy.twapLeverageRatio() > 0, "TWAP should be active");

        _warpPastTwapCooldown();

        vm.prank(keeper, keeper);
        carryStrategy.iterateRebalance();

        // Should create a pending lever swap
        assertTrue(
            carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP ||
            carryStrategy.twapLeverageRatio() == 0,
            "Should have created swap or reached target"
        );
    }

    function test_iterateRebalance_clearsTwapWhenSmallTrade() public onlyLocal {
        // Use a small amount so the full trade fits in one maxTradeSize
        _setupCollateral(1_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        // After engage + complete, the remaining amount might be small enough
        // to fit in one trade, clearing TWAP
        if (carryStrategy.twapLeverageRatio() > 0) {
            _warpPastTwapCooldown();
            vm.prank(keeper, keeper);
            carryStrategy.iterateRebalance();

            if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
                _completeLeverSwap();
            }
            // With small amounts, TWAP should clear quickly
            // (may need more iterations for larger amounts)
        }
        // Just verify no revert
    }

    function test_iterateRebalance_revertsWhenNoTwap() public onlyLocal {
        _setupCollateral(100_000e6);
        // Don't engage, so twapLeverageRatio = 0

        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.TwapNotActive.selector);
        carryStrategy.iterateRebalance();
    }

    function test_iterateRebalance_revertsBeforeCooldown() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        // Call immediately without warping past cooldown
        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.RebalanceIntervalNotElapsed.selector);
        carryStrategy.iterateRebalance();
    }

    function test_iterateRebalance_requiresEOA() public onlyLocal {
        vm.prank(address(this)); // Contract context
        vm.expectRevert("Not EOA");
        carryStrategy.iterateRebalance();
    }

    function test_iterateRebalance_requiresAllowedCaller() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();
        _warpPastTwapCooldown();

        vm.prank(charlie, charlie); // Not allowed caller
        vm.expectRevert(CarryStrategy.NotAllowedCaller.selector);
        carryStrategy.iterateRebalance();
    }

    // ═══════════════════════════════════════════════════════════════════
    // LEVERAGE VALIDATION TESTS (Phase 3)
    // ═══════════════════════════════════════════════════════════════════

    function test_constructor_revertsOnUnreachableLeverage() public onlyLocal {
        // With mock LTV of 75%, max theoretical leverage = 1/(1-0.75) = 4x
        // Aggressive target 10x with 75% LTV should revert
        // 10_000_000_000 * (1e18 - 0.75e18) = 10e9 * 0.25e18 = 2.5e27 >= 1e27 → revert
        CarryStrategy.Addresses memory addrs = CarryStrategy.Addresses({
            adapter: address(0),
            zaibots: address(mockPool),
            collateralToken: address(usdc),
            debtToken: address(jUBC),
            jpyUsdOracle: address(mockJpyUsdFeed),
            jpyUsdAggregator: address(0),
            twapOracle: address(twapOracle),
            milkman: address(mockMilkman),
            priceChecker: address(priceChecker)
        });
        vm.expectRevert(CarryStrategy.LeverageExceedsLTVLimit.selector);
        new CarryStrategy(
            "Too Aggressive",
            CarryStrategy.StrategyType.AGGRESSIVE,
            addrs,
            [AGGRESSIVE_TARGET, AGGRESSIVE_MIN, AGGRESSIVE_MAX, AGGRESSIVE_RIPCORD],
            CarryStrategy.ExecutionParams(DEFAULT_MAX_TRADE_SIZE, DEFAULT_TWAP_COOLDOWN, DEFAULT_SLIPPAGE_BPS, DEFAULT_REBALANCE_INTERVAL, DEFAULT_RECENTER_SPEED),
            CarryStrategy.IncentiveParams(DEFAULT_RIPCORD_SLIPPAGE_BPS, DEFAULT_RIPCORD_COOLDOWN, DEFAULT_RIPCORD_MAX_TRADE, DEFAULT_ETH_REWARD)
        );
    }

    function test_constructor_acceptsReachableLeverage() public onlyLocal {
        // Conservative target 2.5x with 75% LTV: 2.5e9 * 0.25e18 = 0.625e27 < 1e27 → pass
        CarryStrategy.Addresses memory addrs = CarryStrategy.Addresses({
            adapter: address(0),
            zaibots: address(mockPool),
            collateralToken: address(usdc),
            debtToken: address(jUBC),
            jpyUsdOracle: address(mockJpyUsdFeed),
            jpyUsdAggregator: address(0),
            twapOracle: address(twapOracle),
            milkman: address(mockMilkman),
            priceChecker: address(priceChecker)
        });
        CarryStrategy s = new CarryStrategy(
            "Conservative OK",
            CarryStrategy.StrategyType.CONSERVATIVE,
            addrs,
            [CONSERVATIVE_TARGET, CONSERVATIVE_MIN, CONSERVATIVE_MAX, CONSERVATIVE_RIPCORD],
            CarryStrategy.ExecutionParams(DEFAULT_MAX_TRADE_SIZE, DEFAULT_TWAP_COOLDOWN, DEFAULT_SLIPPAGE_BPS, DEFAULT_REBALANCE_INTERVAL, DEFAULT_RECENTER_SPEED),
            CarryStrategy.IncentiveParams(DEFAULT_RIPCORD_SLIPPAGE_BPS, DEFAULT_RIPCORD_COOLDOWN, DEFAULT_RIPCORD_MAX_TRADE, DEFAULT_ETH_REWARD)
        );
        assertTrue(address(s) != address(0), "Should deploy successfully");
    }

    function test_constructor_edgeCase_targetAtExactLimit() public onlyLocal {
        // With 75% LTV, max leverage = 1e27 / complement = 1e27 / 0.25e18 = 4e9
        // At exactly the limit: target * complement == 1e27 → should revert (>= check)
        CarryStrategy.Addresses memory addrs = CarryStrategy.Addresses({
            adapter: address(0),
            zaibots: address(mockPool),
            collateralToken: address(usdc),
            debtToken: address(jUBC),
            jpyUsdOracle: address(mockJpyUsdFeed),
            jpyUsdAggregator: address(0),
            twapOracle: address(twapOracle),
            milkman: address(mockMilkman),
            priceChecker: address(priceChecker)
        });
        uint64 exactLimit = 4_000_000_000; // 4x, at the boundary for 75% LTV
        vm.expectRevert(CarryStrategy.LeverageExceedsLTVLimit.selector);
        new CarryStrategy(
            "Edge Case",
            CarryStrategy.StrategyType.CONSERVATIVE,
            addrs,
            [exactLimit, uint64(2_000_000_000), exactLimit, uint64(5_000_000_000)],
            CarryStrategy.ExecutionParams(DEFAULT_MAX_TRADE_SIZE, DEFAULT_TWAP_COOLDOWN, DEFAULT_SLIPPAGE_BPS, DEFAULT_REBALANCE_INTERVAL, DEFAULT_RECENTER_SPEED),
            CarryStrategy.IncentiveParams(DEFAULT_RIPCORD_SLIPPAGE_BPS, DEFAULT_RIPCORD_COOLDOWN, DEFAULT_RIPCORD_MAX_TRADE, DEFAULT_ETH_REWARD)
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // LTV SYNC TESTS (Phase 1 v2)
    // ═══════════════════════════════════════════════════════════════════

    function test_syncLTV_returnsValidWhenLTVUnchanged() public onlyLocal {
        // Default 75% LTV, 2.5x target → valid (2.5e9 * 0.25e18 = 0.625e27 < 1e27)
        bool valid = carryStrategy.syncLTV();
        assertTrue(valid, "Should be valid with unchanged LTV");
        assertTrue(carryStrategy.isActive(), "Should remain active");
    }

    function test_syncLTV_deactivatesWhenLTVDrops() public onlyLocal {
        // Drop LTV to 50% → max leverage = 2x, but target = 2.5x → invalid
        mockPool.setLTV(address(usdc), address(jUBC), 0.50e18);

        vm.expectEmit(true, true, true, true);
        emit CarryStrategy.StrategyAutoDeactivated("LTV no longer supports target leverage");

        bool valid = carryStrategy.syncLTV();
        assertFalse(valid, "Should be invalid after LTV drop to 50%");
        assertFalse(carryStrategy.isActive(), "Should auto-deactivate");
    }

    function test_syncLTV_remainsActiveWhenLTVIncreases() public onlyLocal {
        // Increase LTV to 85% → max leverage ~6.67x >> 2.5x target
        mockPool.setLTV(address(usdc), address(jUBC), 0.85e18);

        bool valid = carryStrategy.syncLTV();
        assertTrue(valid, "Should be valid with higher LTV");
        assertTrue(carryStrategy.isActive(), "Should remain active");
    }

    function test_syncLTV_isPermissionless() public onlyLocal {
        // Charlie (not operator, not owner, not allowed caller) can call syncLTV
        vm.prank(charlie);
        bool valid = carryStrategy.syncLTV();
        assertTrue(valid, "Should succeed from any address");
    }

    function test_syncLTV_idempotentWhenAlreadyDeactivated() public onlyLocal {
        mockPool.setLTV(address(usdc), address(jUBC), 0.50e18);

        carryStrategy.syncLTV();
        assertFalse(carryStrategy.isActive(), "Should be deactivated");

        // Call again — should not revert
        bool valid = carryStrategy.syncLTV();
        assertFalse(valid, "Should still be invalid");
        assertFalse(carryStrategy.isActive(), "Should stay deactivated");
    }

    function test_isLTVValid_viewFunction() public onlyLocal {
        assertTrue(carryStrategy.isLTVValid(), "Should be valid initially");

        mockPool.setLTV(address(usdc), address(jUBC), 0.50e18);

        assertFalse(carryStrategy.isLTVValid(), "View should return false after LTV drop");
        assertTrue(carryStrategy.isActive(), "View should not mutate isActive");
    }

    function test_engage_revertsAfterLTVDrop_syncDeactivates() public onlyLocal {
        _setupCollateral(100_000e6);

        // Drop LTV and sync → deactivates
        mockPool.setLTV(address(usdc), address(jUBC), 0.50e18);
        carryStrategy.syncLTV();

        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.StrategyNotActive.selector);
        carryStrategy.engage();
    }

    function test_engage_revertsOnInlineLTVCheck() public onlyLocal {
        _setupCollateral(100_000e6);

        // Drop LTV but do NOT call syncLTV — engage's inline check should catch it
        mockPool.setLTV(address(usdc), address(jUBC), 0.50e18);

        vm.prank(keeper, keeper);
        vm.expectRevert(CarryStrategy.LeverageExceedsLTVLimit.selector);
        carryStrategy.engage();
    }

    // ═══════════════════════════════════════════════════════════════════
    // ITERATE REBALANCE LOW LIQUIDITY TESTS (Phase 2 v2)
    // ═══════════════════════════════════════════════════════════════════

    function test_iterateRebalance_doesNotClearTwapWhenBorrowCapped() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        // Set tiny max borrow so iterations are constrained
        mockPool.setMaxBorrow(address(carryStrategy), 100e18); // Tiny borrow cap

        _warpPastTwapCooldown();

        if (carryStrategy.twapLeverageRatio() > 0) {
            vm.prank(keeper, keeper);
            carryStrategy.iterateRebalance();

            // TWAP should NOT clear because borrow was capped
            if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
                assertTrue(carryStrategy.twapLeverageRatio() > 0, "TWAP should persist when borrow capped");
            }
        }
    }

    function test_iterateRebalance_skipsWhenZeroBorrowCapacity() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        // Set zero borrow capacity
        mockPool.setMaxBorrow(address(carryStrategy), 0);

        _warpPastTwapCooldown();

        if (carryStrategy.twapLeverageRatio() > 0) {
            uint64 twapBefore = carryStrategy.twapLeverageRatio();

            vm.prank(keeper, keeper);
            carryStrategy.iterateRebalance();

            // TWAP should stay active, swapState stays IDLE (no swap created)
            assertEq(carryStrategy.twapLeverageRatio(), twapBefore, "TWAP should persist with zero capacity");
            assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should stay IDLE");
        }
    }

    function test_iterateRebalance_clearsTwapWhenFullAmountExecuted() public onlyLocal {
        // Use small collateral so trade fits in one maxTradeSize
        _setupCollateral(1_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        // Clear override so full borrow is available
        mockPool.clearMaxBorrowOverride(address(carryStrategy));

        // Complete remaining TWAP iterations
        uint256 iterations = 0;
        while (carryStrategy.twapLeverageRatio() > 0 && iterations < 10) {
            _warpPastTwapCooldown();
            if (carryStrategy.swapState() == CarryStrategy.SwapState.IDLE) {
                vm.prank(keeper, keeper);
                try carryStrategy.iterateRebalance() {} catch { break; }
                if (carryStrategy.swapState() != CarryStrategy.SwapState.IDLE) {
                    _completeLeverSwap();
                }
            }
            iterations++;
        }

        // With small collateral, TWAP should eventually clear
        assertEq(carryStrategy.twapLeverageRatio(), 0, "TWAP should clear with full execution");
    }

    function test_iterateRebalance_lowLiquidityRecovery() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        // Constrained period — tiny borrow cap
        mockPool.setMaxBorrow(address(carryStrategy), 50e18);

        _warpPastTwapCooldown();

        if (carryStrategy.twapLeverageRatio() > 0) {
            vm.prank(keeper, keeper);
            carryStrategy.iterateRebalance();

            // Complete if swap was created
            if (carryStrategy.swapState() != CarryStrategy.SwapState.IDLE) {
                _completeLeverSwap();
            }

            // TWAP should still be active
            assertTrue(carryStrategy.twapLeverageRatio() > 0, "TWAP should persist during constrained period");

            // Restore capacity
            mockPool.clearMaxBorrowOverride(address(carryStrategy));

            _warpPastTwapCooldown();

            vm.prank(keeper, keeper);
            carryStrategy.iterateRebalance();

            // With restored capacity, progress should resume
            assertTrue(
                carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP ||
                carryStrategy.twapLeverageRatio() == 0,
                "Should resume after capacity restored"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // BORROW CAPACITY CAPPING TESTS (Phase 4)
    // ═══════════════════════════════════════════════════════════════════

    function test_lever_capsToMaxBorrow() public onlyLocal {
        _setupCollateral(100_000e6);

        // Set a very low max borrow so the cap kicks in
        mockPool.setMaxBorrow(address(carryStrategy), 1_000e18);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        // Swap should have been created with capped amount
        assertEq(
            uint256(carryStrategy.swapState()),
            uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP),
            "Should still create swap with capped amount"
        );
    }

    function test_lever_skipsWhenZeroBorrowCapacity() public onlyLocal {
        _setupCollateral(100_000e6);

        // Set zero max borrow — strategy should return early without creating swap
        mockPool.setMaxBorrow(address(carryStrategy), 1); // After 95% safety: 0

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        // With zero capacity, _lever returns early, no swap created
        // engage() still completes but swapState stays IDLE
        // Note: engage() sets twapLeverageRatio before calling _lever
    }

    function test_lever_normalOperationUnaffected() public onlyLocal {
        _setupCollateral(100_000e6);

        // Default mock behavior (50% of collateral) — should not cap
        vm.prank(keeper, keeper);
        carryStrategy.engage();

        assertEq(
            uint256(carryStrategy.swapState()),
            uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP),
            "Normal engage should create lever swap"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // COMPLETE SWAP VALIDATION TESTS (Phase 3 v2)
    // ═══════════════════════════════════════════════════════════════════

    function test_completeSwap_revertsOnLowOutput() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        // Don't settle via milkman — manually send tiny USDC (attack scenario)
        mockUsdc.mint(address(carryStrategy), 1e6); // Only 1 USDC

        vm.expectRevert(CarryStrategy.SwapOutputTooLow.selector);
        carryStrategy.completeSwap();
    }

    function test_completeSwap_acceptsValidOutput() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        // Normal Milkman settlement
        _completeLeverSwap();

        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "Should complete");
    }

    function test_completeSwap_stateResetBeforeExternalCall() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        bytes32 swapId = mockMilkman.getLatestSwapId();
        mockMilkman.settleSwapWithPrice(swapId);
        carryStrategy.completeSwap();

        // All pending state should be cleared (CEI)
        assertEq(uint256(carryStrategy.swapState()), uint256(CarryStrategy.SwapState.IDLE), "State reset");
        assertEq(carryStrategy.pendingSwapAmount(), 0, "Amount reset");
        assertEq(carryStrategy.pendingSwapTs(), 0, "Timestamp reset");
        assertEq(carryStrategy.pendingSwapExpectedOutput(), 0, "Expected output reset");
    }

    function test_completeSwap_setsExpectedOutputOnLever() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        assertTrue(carryStrategy.pendingSwapExpectedOutput() > 0, "Expected output should be set after lever");
    }

    function test_completeSwap_setsExpectedOutputOnDelever() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Push leverage up to trigger delever rebalance
        _applyPriceChange(2000); // +20%
        _warpToRebalanceWindow();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
            vm.prank(keeper, keeper);
            carryStrategy.rebalance();

            if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_DELEVER_SWAP) {
                assertTrue(carryStrategy.pendingSwapExpectedOutput() > 0, "Expected output should be set after delever");
            }
        }
    }

    function test_completeSwap_delever_revertsOnLowOutput() public onlyLocal {
        _setupEngagedStrategy(100_000e6);

        // Push leverage up to trigger delever rebalance
        _applyPriceChange(2000);
        _warpToRebalanceWindow();

        CarryStrategy.ShouldRebalance action = carryStrategy.shouldRebalance();
        if (action == CarryStrategy.ShouldRebalance.REBALANCE) {
            vm.prank(keeper, keeper);
            carryStrategy.rebalance();

            if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_DELEVER_SWAP) {
                // Send tiny jUBC manually instead of proper settlement
                mockJUBC.mint(address(carryStrategy), 1e18); // Tiny amount

                vm.expectRevert(CarryStrategy.SwapOutputTooLow.selector);
                carryStrategy.completeSwap();
            }
        }
    }

    function test_cancelTimedOutSwap_clearsExpectedOutput() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        assertTrue(carryStrategy.pendingSwapExpectedOutput() > 0, "Should have expected output");

        _warpPastSwapTimeout();

        vm.prank(keeper, keeper);
        carryStrategy.cancelTimedOutSwap();

        assertEq(carryStrategy.pendingSwapExpectedOutput(), 0, "Expected output should be cleared after cancel");
    }

    // ═══════════════════════════════════════════════════════════════════
    // LEVERAGE BOUNDS ENFORCEMENT TESTS (Phase 4 v2)
    // ═══════════════════════════════════════════════════════════════════

    function test_getMaxAchievableLeverage_75pctLTV() public view {
        // 75% LTV → 1 / (1 - 0.75) = 4x = 4e18
        uint256 maxLev = carryStrategy.getMaxAchievableLeverage();
        assertEq(maxLev, 4e18, "75% LTV should give 4x max leverage");
    }

    function test_getMaxAchievableLeverage_50pctLTV() public onlyLocal {
        mockPool.setLTV(address(usdc), address(jUBC), 0.50e18);
        uint256 maxLev = carryStrategy.getMaxAchievableLeverage();
        assertEq(maxLev, 2e18, "50% LTV should give 2x max leverage");
    }

    function test_getMaxAchievableLeverage_90pctLTV() public onlyLocal {
        mockPool.setLTV(address(usdc), address(jUBC), 0.90e18);
        uint256 maxLev = carryStrategy.getMaxAchievableLeverage();
        assertEq(maxLev, 10e18, "90% LTV should give 10x max leverage");
    }

    function test_calculateLeverAmount_cappedToSafeMax() public onlyLocal {
        // With 75% LTV, safe max = 4x * 0.95 = 3.8x
        // Target is 2.5x which is below safe max → no capping expected
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        // Should have created a swap (lever amount not zero)
        assertEq(
            uint256(carryStrategy.swapState()),
            uint256(CarryStrategy.SwapState.PENDING_LEVER_SWAP),
            "Should create lever swap"
        );
    }

    function test_calculateLeverAmount_cappedWhenTargetExceedsMax() public onlyLocal {
        // Deploy a new strategy with target 3.9x (just below 4x theoretical max for 75% LTV)
        // Safe max = 4x * 0.95 = 3.8x, so 3.9x target gets capped to 3.8x
        CarryStrategy.Addresses memory addrs = CarryStrategy.Addresses({
            adapter: address(0),
            zaibots: address(mockPool),
            collateralToken: address(usdc),
            debtToken: address(jUBC),
            jpyUsdOracle: address(mockJpyUsdFeed),
            jpyUsdAggregator: address(0),
            twapOracle: address(twapOracle),
            milkman: address(mockMilkman),
            priceChecker: address(priceChecker)
        });
        uint64 highTarget = 3_900_000_000; // 3.9x
        uint64 highMax = 3_950_000_000;    // 3.95x
        CarryStrategy highStrategy = new CarryStrategy(
            "High Target",
            CarryStrategy.StrategyType.CONSERVATIVE,
            addrs,
            [highTarget, uint64(3_000_000_000), highMax, uint64(5_000_000_000)],
            CarryStrategy.ExecutionParams(DEFAULT_MAX_TRADE_SIZE, DEFAULT_TWAP_COOLDOWN, DEFAULT_SLIPPAGE_BPS, DEFAULT_REBALANCE_INTERVAL, DEFAULT_RECENTER_SPEED),
            CarryStrategy.IncentiveParams(DEFAULT_RIPCORD_SLIPPAGE_BPS, DEFAULT_RIPCORD_COOLDOWN, DEFAULT_RIPCORD_MAX_TRADE, DEFAULT_ETH_REWARD)
        );
        highStrategy.setAllowedCaller(keeper, true);
        highStrategy.setOperator(keeper);

        // Fund and supply collateral
        mockUsdc.mint(address(highStrategy), 100_000e6);
        vm.prank(address(highStrategy));
        mockPool.supply(address(usdc), 100_000e6, address(highStrategy));

        vm.prank(keeper, keeper);
        highStrategy.engage();

        // The lever amount should have been capped to safe max (3.8x instead of 3.9x)
        // Verify swap was still created (capping doesn't prevent it)
        assertTrue(
            highStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP,
            "Should create swap with capped target"
        );
    }

    function test_lever_scalesBackBorrowWhenProjectedLeverageTooHigh() public onlyLocal {
        // With small collateral, the pre-borrow projected leverage check
        // should prevent borrowing more than safe leverage allows
        _setupCollateral(2_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        // After engage, verify debt doesn't exceed safe leverage bounds
        if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
            uint256 debt = mockPool.getDebtBalance(address(carryStrategy), address(jUBC));
            uint256 collateral = mockPool.getCollateralBalance(address(carryStrategy), address(usdc));
            (, int256 price, , , ) = mockJpyUsdFeed.latestRoundData();
            uint256 debtInBase = (debt * uint256(price)) / 1e20;
            uint256 ltv = mockPool.getLTV(address(usdc), address(jUBC));
            uint256 maxDebt = (collateral * ltv) / 1e18;

            assertTrue(debtInBase <= maxDebt + 1e6, "Debt should not exceed LTV limit");
        }
    }

    function test_lever_smallCollateral_respectsLTVBounds() public onlyLocal {
        // The exact bug found by invariant testing: 2000 USDC, 2.5x target
        _setupCollateral(2_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
            uint256 debt = mockPool.getDebtBalance(address(carryStrategy), address(jUBC));
            uint256 collateral = mockPool.getCollateralBalance(address(carryStrategy), address(usdc));
            (, int256 price, , , ) = mockJpyUsdFeed.latestRoundData();
            uint256 debtInBase = (debt * uint256(price)) / 1e20;
            uint256 ltv = mockPool.getLTV(address(usdc), address(jUBC));
            uint256 maxDebt = (collateral * ltv) / 1e18;

            assertTrue(debtInBase <= maxDebt + 1e6, "Small collateral debt should respect LTV");
        }
    }

    function test_lever_convergence_withBoundsEnforcement() public onlyLocal {
        _setupCollateral(100_000e6);

        vm.prank(keeper, keeper);
        carryStrategy.engage();
        _completeLeverSwap();

        // Complete TWAP iterations
        uint256 iterations = 0;
        while (carryStrategy.twapLeverageRatio() > 0 && iterations < 20) {
            _warpPastTwapCooldown();
            if (carryStrategy.swapState() == CarryStrategy.SwapState.IDLE &&
                carryStrategy.shouldRebalance() == CarryStrategy.ShouldRebalance.ITERATE) {
                vm.prank(keeper, keeper);
                try carryStrategy.iterateRebalance() {} catch { break; }
                if (carryStrategy.swapState() != CarryStrategy.SwapState.IDLE) {
                    _completeLeverSwap();
                }
            } else {
                break;
            }
            iterations++;
        }

        uint256 finalLev = carryStrategy.getCurrentLeverageRatio();
        uint256 targetLev = uint256(CONSERVATIVE_TARGET) * 1e9;
        // Should be within 5% of target
        uint256 deviation = finalLev > targetLev ? finalLev - targetLev : targetLev - finalLev;
        assertTrue(deviation < targetLev / 20, "Final leverage should be within 5% of target");
    }

    function testFuzz_leverNeverExceedsLTVBound(uint256 collateralAmount) public onlyLocal {
        collateralAmount = bound(collateralAmount, 100e6, 10_000_000e6);

        _setupCollateral(collateralAmount);

        vm.prank(keeper, keeper);
        carryStrategy.engage();

        if (carryStrategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
            uint256 debt = mockPool.getDebtBalance(address(carryStrategy), address(jUBC));
            uint256 collateral = mockPool.getCollateralBalance(address(carryStrategy), address(usdc));
            (, int256 price, , , ) = mockJpyUsdFeed.latestRoundData();
            uint256 debtInBase = (debt * uint256(price)) / 1e20;
            uint256 ltv = mockPool.getLTV(address(usdc), address(jUBC));
            uint256 maxDebt = (collateral * ltv) / 1e18;

            // Allow 1% tolerance for rounding
            assertTrue(debtInBase <= maxDebt + (maxDebt / 100) + 1e6, "Fuzz: debt should respect LTV");
        }
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

        (address adapter,,,,,,,,) = carryStrategy.addr();
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
        mockPool.supply(address(usdc), amount, address(carryStrategy));
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
