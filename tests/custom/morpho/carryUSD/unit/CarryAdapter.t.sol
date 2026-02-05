// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TestCarryUSDBase} from "../base/TestCarryUSDBase.sol";
import {CarryAdapter, ICarryStrategy} from "custom/integrations/morpho/adapters/CarryAdapter.sol";

/**
 * @title CarryAdapterTest
 * @notice Unit tests for CarryAdapter contract
 * @dev Tests adapter-vault integration and risk tracking
 */
contract CarryAdapterTest is TestCarryUSDBase {
    // ═══════════════════════════════════════════════════════════════════
    // SETUP VERIFICATION
    // ═══════════════════════════════════════════════════════════════════

    function test_setup_adapterDeployed() public view {
        assertTrue(address(carryAdapter) != address(0), "Adapter should be deployed");
    }

    function test_setup_strategyConnected() public view {
        assertEq(address(carryAdapter.strategy()), address(carryStrategy), "Strategy should be connected");
    }

    function test_setup_correctAsset() public view {
        assertEq(address(carryAdapter.asset()), address(usdc), "Asset should be USDC");
    }

    function test_setup_correctStrategyRiskId() public view {
        bytes32 expectedRiskId = keccak256(abi.encodePacked("strategy:", "conservative-usdc"));
        assertEq(carryAdapter.strategyRiskId(), expectedRiskId, "Strategy risk ID should match");
    }

    // ═══════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════

    function test_init_ownerIsDeployer() public view {
        assertEq(carryAdapter.owner(), owner, "Owner should be deployer");
    }

    function test_init_vaultIsSet() public view {
        // In local mode, vault is address(1) placeholder
        assertTrue(carryAdapter.vault() != address(0), "Vault should be set");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════

    function test_acl_onlyOwnerCanSetStrategy() public {
        vm.prank(alice);
        vm.expectRevert();
        carryAdapter.setStrategy(address(0x123));

        vm.prank(owner);
        carryAdapter.setStrategy(address(0x123));
        assertEq(address(carryAdapter.strategy()), address(0x123), "Strategy should be updated");

        // Reset
        vm.prank(owner);
        carryAdapter.setStrategy(address(carryStrategy));
    }

    function test_acl_onlyOwnerCanTransferOwnership() public {
        vm.prank(alice);
        vm.expectRevert();
        carryAdapter.transferOwnership(alice);
    }

    // ═══════════════════════════════════════════════════════════════════
    // REAL ASSETS TRACKING
    // ═══════════════════════════════════════════════════════════════════

    function test_realAssets_initiallyZero() public view {
        assertEq(carryAdapter.realAssets(), 0, "Real assets should be 0 initially");
    }

    function test_realAssets_matchesStrategy() public view {
        uint256 adapterAssets = carryAdapter.realAssets();
        uint256 strategyAssets = carryStrategy.getRealAssets();
        assertEq(adapterAssets, strategyAssets, "Real assets should match strategy");
    }

    // ═══════════════════════════════════════════════════════════════════
    // RISK ID TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_ids_returnsExpectedRisks() public view {
        bytes32[] memory riskIds = carryAdapter.ids();
        assertEq(riskIds.length, 3, "Should have 3 risk IDs");

        // Check for expected risks
        bytes32 RISK_ID_ZAIBOTS = keccak256("zaibots-protocol");
        bytes32 RISK_ID_JPY_FX = keccak256("jpy-fx-exposure");
        bytes32 expectedStrategyRiskId = keccak256(abi.encodePacked("strategy:", "conservative-usdc"));

        assertEq(riskIds[0], RISK_ID_ZAIBOTS, "First risk should be zaibots");
        assertEq(riskIds[1], RISK_ID_JPY_FX, "Second risk should be JPY FX");
        assertEq(riskIds[2], expectedStrategyRiskId, "Third risk should be strategy ID");
    }

    // ═══════════════════════════════════════════════════════════════════
    // TWAP ORACLE INTEGRATION
    // ═══════════════════════════════════════════════════════════════════

    function test_twapOracle_isConnected() public view {
        assertEq(address(carryAdapter.twapOracle()), address(twapOracle), "TWAP oracle should be connected");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ALLOCATION TESTS (require vault integration)
    // ═══════════════════════════════════════════════════════════════════

    function test_allocate_revertsIfNotVault() public {
        vm.prank(alice);
        vm.expectRevert();
        carryAdapter.allocate(bytes(""), 1000e6, bytes4(0), alice);
    }

    function test_deallocate_revertsIfNotVault() public {
        vm.prank(alice);
        vm.expectRevert();
        carryAdapter.deallocate(bytes(""), 1000e6, bytes4(0), alice);
    }
}
