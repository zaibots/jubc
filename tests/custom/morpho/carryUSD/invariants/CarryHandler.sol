// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "../../../lib/TestUtils.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockMilkman} from "../mocks/MockMilkman.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

import {CarryStrategy} from "custom/products/carryUSDC/CarryStrategy.sol";
import {CarryAdapter} from "custom/integrations/morpho/adapters/CarryAdapter.sol";
import {LinearBlockTwapOracle} from "custom/products/carryUSDC/LinearBlockTwapOracle.sol";
import {CarryKeeper} from "custom/products/carryUSDC/CarryKeeper.sol";

/**
 * @title CarryHandler
 * @notice Stateful fuzzing handler for Carry strategy invariant tests
 * @dev Tracks ghost variables and executes randomized actions
 */
contract CarryHandler is Test {
    // ═══════════════════════════════════════════════════════════════════
    // CONTRACTS
    // ═══════════════════════════════════════════════════════════════════

    CarryStrategy public strategy;
    CarryAdapter public adapter;
    LinearBlockTwapOracle public oracle;
    CarryKeeper public keeper;
    MockAavePool public zaibots;
    MockMilkman public milkman;
    MockChainlinkFeed public priceFeed;
    MockERC20 public usdc;
    MockERC20 public jUBC;

    // ═══════════════════════════════════════════════════════════════════
    // ACTORS
    // ═══════════════════════════════════════════════════════════════════

    address[] public actors;
    address public currentActor;

    // ═══════════════════════════════════════════════════════════════════
    // GHOST VARIABLES
    // ═══════════════════════════════════════════════════════════════════

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_leverSwaps;
    uint256 public ghost_deleverSwaps;
    uint256 public ghost_ripcords;
    uint256 public ghost_cancelledSwaps;
    uint256 public ghost_timeWarped;
    int256 public ghost_cumulativePriceChange;

    // Action call counts
    mapping(bytes4 => uint256) public calls;

    // ═══════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    uint256 constant MIN_DEPOSIT = 100e6;
    uint256 constant MAX_DEPOSIT = 10_000_000e6;
    int256 constant MIN_PRICE_CHANGE = -2000; // -20%
    int256 constant MAX_PRICE_CHANGE = 2000;  // +20%
    uint256 constant MIN_TIME_WARP = 1 minutes;
    uint256 constant MAX_TIME_WARP = 1 days;
    int256 constant BASE_PRICE = 650_000;

    // ═══════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    constructor(
        CarryStrategy _strategy,
        CarryAdapter _adapter,
        LinearBlockTwapOracle _oracle,
        CarryKeeper _keeper,
        MockAavePool _zaibots,
        MockMilkman _milkman,
        MockChainlinkFeed _priceFeed,
        MockERC20 _usdc,
        MockERC20 _jUBC,
        address[] memory _actors
    ) {
        strategy = _strategy;
        adapter = _adapter;
        oracle = _oracle;
        keeper = _keeper;
        zaibots = _zaibots;
        milkman = _milkman;
        priceFeed = _priceFeed;
        usdc = _usdc;
        jUBC = _jUBC;
        actors = _actors;
    }

    // ═══════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor, currentActor);
        _;
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // DEPOSIT/WITHDRAW ACTIONS
    // ═══════════════════════════════════════════════════════════════════

    function deposit(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        calls[this.deposit.selector]++;

        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);

        // Mint USDC to strategy and supply to zaibots
        usdc.mint(address(strategy), amount);
        vm.stopPrank();

        vm.startPrank(address(strategy));
        usdc.approve(address(zaibots), amount);
        zaibots.supply(address(usdc), amount, address(strategy));
        vm.stopPrank();

        ghost_totalDeposited += amount;

        vm.startPrank(currentActor, currentActor);
    }

    // ═══════════════════════════════════════════════════════════════════
    // LEVERAGE ACTIONS
    // ═══════════════════════════════════════════════════════════════════

    function engage(uint256 actorSeed) external useActor(actorSeed) {
        calls[this.engage.selector]++;

        if (strategy.swapState() != CarryStrategy.SwapState.IDLE) return;
        if (strategy.getCurrentLeverageRatio() > 1e18 + 1e16) return;
        if (zaibots.getCollateralBalance(address(strategy), address(usdc)) == 0) return;

        try strategy.engage() {
            ghost_leverSwaps++;
        } catch {}
    }

    function rebalance(uint256 actorSeed) external useActor(actorSeed) {
        calls[this.rebalance.selector]++;

        if (strategy.swapState() != CarryStrategy.SwapState.IDLE) return;

        CarryStrategy.ShouldRebalance action = strategy.shouldRebalance();
        if (action != CarryStrategy.ShouldRebalance.REBALANCE) return;

        try strategy.rebalance() {
            if (strategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
                ghost_leverSwaps++;
            } else {
                ghost_deleverSwaps++;
            }
        } catch {}
    }

    function iterateRebalance(uint256 actorSeed) external useActor(actorSeed) {
        calls[this.iterateRebalance.selector]++;

        if (strategy.twapLeverageRatio() == 0) return;
        if (strategy.swapState() != CarryStrategy.SwapState.IDLE) return;

        try strategy.iterateRebalance() {
            if (strategy.swapState() == CarryStrategy.SwapState.PENDING_LEVER_SWAP) {
                ghost_leverSwaps++;
            } else if (strategy.swapState() == CarryStrategy.SwapState.PENDING_DELEVER_SWAP) {
                ghost_deleverSwaps++;
            }
        } catch {}
    }

    function ripcord(uint256 actorSeed) external useActor(actorSeed) {
        calls[this.ripcord.selector]++;

        CarryStrategy.ShouldRebalance action = strategy.shouldRebalance();
        if (action != CarryStrategy.ShouldRebalance.RIPCORD) return;

        try strategy.ripcord() {
            ghost_ripcords++;
            ghost_deleverSwaps++;
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // SWAP COMPLETION ACTIONS
    // ═══════════════════════════════════════════════════════════════════

    function completeLeverSwap(uint256 actorSeed) external useActor(actorSeed) {
        calls[this.completeLeverSwap.selector]++;

        if (strategy.swapState() != CarryStrategy.SwapState.PENDING_LEVER_SWAP) return;

        bytes32 swapId = milkman.getLatestSwapId();
        milkman.settleSwapWithPrice(swapId);
        vm.stopPrank();
        try strategy.completeSwap() {} catch {}
        vm.startPrank(currentActor, currentActor);
    }

    function completeDeleverSwap(uint256 actorSeed) external useActor(actorSeed) {
        calls[this.completeDeleverSwap.selector]++;

        if (strategy.swapState() != CarryStrategy.SwapState.PENDING_DELEVER_SWAP) return;

        bytes32 swapId = milkman.getLatestSwapId();
        milkman.settleSwapWithPrice(swapId);
        vm.stopPrank();
        try strategy.completeSwap() {} catch {}
        vm.startPrank(currentActor, currentActor);
    }

    function cancelTimedOutSwap(uint256 actorSeed) external useActor(actorSeed) {
        calls[this.cancelTimedOutSwap.selector]++;

        if (strategy.swapState() == CarryStrategy.SwapState.IDLE) return;
        if (block.timestamp < strategy.pendingSwapTs() + strategy.SWAP_TIMEOUT()) return;

        try strategy.cancelTimedOutSwap() {
            ghost_cancelledSwaps++;
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // LTV SYNC
    // ═══════════════════════════════════════════════════════════════════

    function syncLTV() external {
        calls[this.syncLTV.selector]++;
        try strategy.syncLTV() {} catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // PRICE/TIME MANIPULATION
    // ═══════════════════════════════════════════════════════════════════

    function movePrice(int256 bpsChange) external {
        calls[this.movePrice.selector]++;

        bpsChange = int256(bound(uint256(bpsChange > 0 ? bpsChange : -bpsChange), 0, uint256(MAX_PRICE_CHANGE)));
        if (bpsChange > MAX_PRICE_CHANGE) bpsChange = MAX_PRICE_CHANGE;
        if (bpsChange < MIN_PRICE_CHANGE) bpsChange = MIN_PRICE_CHANGE;

        priceFeed.applyPercentageChange(bpsChange);
        ghost_cumulativePriceChange += bpsChange;
    }

    function warpTime(uint256 seconds_) external {
        calls[this.warpTime.selector]++;

        seconds_ = bound(seconds_, MIN_TIME_WARP, MAX_TIME_WARP);
        vm.warp(block.timestamp + seconds_);
        priceFeed.setUpdatedAt(block.timestamp);
        ghost_timeWarped += seconds_;
    }

    function warpBlocks(uint256 blocks) external {
        calls[this.warpBlocks.selector]++;

        blocks = bound(blocks, 1, 1000);
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 12);
        priceFeed.setUpdatedAt(block.timestamp);
    }

    function updateTwap() external {
        calls[this.updateTwap.selector]++;

        try oracle.updateTwap() {} catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // SUMMARY
    // ═══════════════════════════════════════════════════════════════════

    function callSummary() external view {
        console2.log("Call Summary:");
        console2.log("  deposit:", calls[this.deposit.selector]);
        console2.log("  engage:", calls[this.engage.selector]);
        console2.log("  rebalance:", calls[this.rebalance.selector]);
        console2.log("  iterateRebalance:", calls[this.iterateRebalance.selector]);
        console2.log("  ripcord:", calls[this.ripcord.selector]);
        console2.log("  completeLeverSwap:", calls[this.completeLeverSwap.selector]);
        console2.log("  completeDeleverSwap:", calls[this.completeDeleverSwap.selector]);
        console2.log("  cancelTimedOutSwap:", calls[this.cancelTimedOutSwap.selector]);
        console2.log("  movePrice:", calls[this.movePrice.selector]);
        console2.log("  warpTime:", calls[this.warpTime.selector]);
        console2.log("  warpBlocks:", calls[this.warpBlocks.selector]);
        console2.log("  updateTwap:", calls[this.updateTwap.selector]);
        console2.log("  syncLTV:", calls[this.syncLTV.selector]);
        console2.log("");
        console2.log("Ghost Variables:");
        console2.log("  totalDeposited:", ghost_totalDeposited);
        console2.log("  totalWithdrawn:", ghost_totalWithdrawn);
        console2.log("  leverSwaps:", ghost_leverSwaps);
        console2.log("  deleverSwaps:", ghost_deleverSwaps);
        console2.log("  ripcords:", ghost_ripcords);
        console2.log("  cancelledSwaps:", ghost_cancelledSwaps);
        console2.log("  cumulativePriceChange:", ghost_cumulativePriceChange);
    }
}
