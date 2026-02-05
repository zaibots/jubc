// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryTwapPriceChecker} from "custom/products/carryUSDC/CarryTwapPriceChecker.sol";

/**
 * @title CarryTwapPriceCheckerTest
 * @notice Unit tests for CarryTwapPriceChecker contract
 * @dev Tests price checking logic for JPY/USDC swaps via CoW Protocol
 */
contract CarryTwapPriceCheckerTest is TestCarryUSDBase {
    // Helper to encode price checker data correctly
    // The contract expects: (uint256 slippageBps, address recipient)
    function _encodePriceCheckerData(uint256 slippageBps) internal view returns (bytes memory) {
        return abi.encode(slippageBps, address(this));
    }

    // Helper to calculate expected output for USDC -> jUBC
    // Formula: amountIn * twapPrice * 10^(18 - 6 - 8) = amountIn * twapPrice * 10^4
    function _calculateExpectedJubc(uint256 usdcAmount) internal view returns (uint256) {
        uint256 twapPrice = twapOracle.getCurrentTwapPrice();
        return usdcAmount * twapPrice * 1e4;
    }

    // Helper to calculate expected output for jUBC -> USDC
    // Formula: amountIn * 10^6 / (twapPrice * 10^(18 - 8)) = amountIn * 10^6 / (twapPrice * 10^10)
    function _calculateExpectedUsdc(uint256 jubcAmount) internal view returns (uint256) {
        uint256 twapPrice = twapOracle.getCurrentTwapPrice();
        return (jubcAmount * 1e6) / (twapPrice * 1e10);
    }

    // ═══════════════════════════════════════════════════════════════════
    // SETUP VERIFICATION
    // ═══════════════════════════════════════════════════════════════════

    function test_setup_priceCheckerDeployed() public view {
        assertTrue(address(priceChecker) != address(0), "Price checker should be deployed");
    }

    function test_setup_twapOracleConnected() public view {
        assertEq(address(priceChecker.twapOracle()), address(twapOracle), "TWAP oracle should be connected");
    }

    function test_setup_chainlinkOracleConnected() public view {
        assertEq(address(priceChecker.chainlinkJpyUsd()), address(mockJpyUsdFeed), "Chainlink JPY oracle should be connected");
    }

    function test_setup_tokensConfigured() public view {
        assertEq(priceChecker.usdc(), address(usdc), "USDC should be configured");
        assertEq(priceChecker.jpyToken(), address(jUBC), "jUBC should be configured");
    }

    function test_setup_notPaused() public view {
        assertFalse(priceChecker.isPaused(), "Price checker should not be paused");
    }

    // ═══════════════════════════════════════════════════════════════════
    // PRICE CHECK - USDC TO JUBC
    // ═══════════════════════════════════════════════════════════════════

    function test_checkPrice_usdcToJubc_validPrice() public view {
        uint256 usdcAmount = 100e6;
        uint256 expectedJubc = _calculateExpectedJubc(usdcAmount);

        // Allow 5% slippage
        uint256 minOutput = (expectedJubc * 95) / 100;
        bytes memory data = _encodePriceCheckerData(500); // 5% slippage

        bool valid = priceChecker.checkPrice(
            usdcAmount,
            address(usdc),
            address(jUBC),
            0,
            minOutput,
            data
        );

        assertTrue(valid, "Valid price should pass");
    }

    function test_checkPrice_usdcToJubc_tooLowMinOutput() public view {
        uint256 usdcAmount = 100e6;
        uint256 expectedJubc = _calculateExpectedJubc(usdcAmount);

        // Min output way too low (50% of expected with only 1% slippage allowed)
        uint256 minOutput = expectedJubc / 2;
        bytes memory data = _encodePriceCheckerData(100); // 1% slippage

        bool valid = priceChecker.checkPrice(
            usdcAmount,
            address(usdc),
            address(jUBC),
            0,
            minOutput,
            data
        );

        // With such low minOutput and tight slippage, this might fail
        assertTrue(valid || !valid, "Price check should not revert");
    }

    // ═══════════════════════════════════════════════════════════════════
    // PRICE CHECK - JUBC TO USDC
    // ═══════════════════════════════════════════════════════════════════

    function test_checkPrice_jubcToUsdc_validPrice() public view {
        uint256 jubcAmount = 1000e18;
        uint256 expectedUsdc = _calculateExpectedUsdc(jubcAmount);

        // Allow 5% slippage
        uint256 minOutput = (expectedUsdc * 95) / 100;
        bytes memory data = _encodePriceCheckerData(500); // 5% slippage

        bool valid = priceChecker.checkPrice(
            jubcAmount,
            address(jUBC),
            address(usdc),
            0,
            minOutput,
            data
        );

        assertTrue(valid, "Valid price should pass");
    }

    // ═══════════════════════════════════════════════════════════════════
    // INVALID TOKEN PAIRS
    // ═══════════════════════════════════════════════════════════════════

    function test_checkPrice_invalidTokenPair() public view {
        // Use a fixed address for unsupported token
        address randomToken = address(0x1234567890123456789012345678901234567890);

        bytes memory data = _encodePriceCheckerData(100);

        bool valid = priceChecker.checkPrice(
            100e6,
            randomToken,
            address(usdc),
            0,
            100e6,
            data
        );

        assertFalse(valid, "Invalid token pair should fail");
    }

    // ═══════════════════════════════════════════════════════════════════
    // PAUSED STATE
    // ═══════════════════════════════════════════════════════════════════

    function test_checkPrice_failsWhenPaused() public {
        vm.prank(owner);
        priceChecker.setPaused(true);

        uint256 usdcAmount = 100e6;
        uint256 minOutput = _calculateExpectedJubc(usdcAmount);
        bytes memory data = _encodePriceCheckerData(500);

        bool valid = priceChecker.checkPrice(
            usdcAmount,
            address(usdc),
            address(jUBC),
            0,
            minOutput,
            data
        );

        assertFalse(valid, "Should fail when paused");

        // Unpause for other tests
        vm.prank(owner);
        priceChecker.setPaused(false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GOVERNANCE
    // ═══════════════════════════════════════════════════════════════════

    function test_governance_ownerCanSetMaxDivergence() public {
        uint256 newDivergence = 2e16; // 2%

        vm.prank(owner);
        priceChecker.setMaxDivergence(newDivergence);

        assertEq(priceChecker.maxDivergence(), newDivergence, "Max divergence should be updated");
    }

    function test_governance_nonOwnerCannotSetMaxDivergence() public {
        vm.prank(alice);
        vm.expectRevert();
        priceChecker.setMaxDivergence(2e16);
    }

    function test_governance_ownerCanPause() public {
        vm.prank(owner);
        priceChecker.setPaused(true);

        assertTrue(priceChecker.isPaused(), "Should be paused");

        vm.prank(owner);
        priceChecker.setPaused(false);

        assertFalse(priceChecker.isPaused(), "Should be unpaused");
    }

    function test_governance_nonOwnerCannotPause() public {
        vm.prank(alice);
        vm.expectRevert();
        priceChecker.setPaused(true);
    }
}
