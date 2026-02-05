// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockMilkman
 * @notice Configurable mock of Milkman/CoW Protocol swap router for testing
 * @dev Simulates swap requests, settlements, and timeouts
 *      Does not implement IMilkman interface directly as mock has simpler testing API
 */
contract MockMilkman {
    // ═══════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════

    struct PendingSwap {
        address requester;
        uint256 amountIn;
        address fromToken;
        address toToken;
        address recipient;
        address priceChecker;
        bytes priceCheckerData;
        uint256 createdAt;
        bool settled;
        bool cancelled;
    }

    // ═══════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════

    mapping(bytes32 => PendingSwap) public pendingSwaps;
    bytes32[] public swapIds;
    uint256 public swapCounter;

    // Configurable behavior
    bool public shouldAutoSettle;
    uint256 public autoSettlementDelay;
    uint256 public outputMultiplier = 1e18; // 1e18 = 1:1, can simulate slippage
    bool public shouldRevertOnRequest;
    bool public shouldFailPriceCheck;

    // Price simulation (for output calculation)
    // fromToken => toToken => price (scaled by 1e18)
    mapping(address => mapping(address => uint256)) public mockPrices;

    // Events
    event SwapRequested(
        bytes32 indexed swapId,
        address indexed requester,
        address fromToken,
        address toToken,
        uint256 amountIn
    );
    event SwapSettled(bytes32 indexed swapId, uint256 amountOut);
    event SwapCancelled(bytes32 indexed swapId);

    // ═══════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════

    function setAutoSettle(bool enabled, uint256 delay) external {
        shouldAutoSettle = enabled;
        autoSettlementDelay = delay;
    }

    function setOutputMultiplier(uint256 multiplier) external {
        outputMultiplier = multiplier;
    }

    function setShouldRevert(bool shouldRevert) external {
        shouldRevertOnRequest = shouldRevert;
    }

    function setShouldFailPriceCheck(bool shouldFail) external {
        shouldFailPriceCheck = shouldFail;
    }

    function setMockPrice(address from, address to, uint256 price) external {
        mockPrices[from][to] = price;
    }

    // ═══════════════════════════════════════════════════════════════════
    // MILKMAN-COMPATIBLE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Request a swap (matches IMilkman signature)
    function requestSwapExactTokensForTokens(
        uint256 amountIn,
        IERC20 fromToken,
        IERC20 toToken,
        address recipient,
        address priceChecker,
        bytes calldata priceCheckerData
    ) external {
        require(!shouldRevertOnRequest, "MockMilkman: request reverted");

        swapCounter++;
        bytes32 swapId = keccak256(abi.encodePacked(msg.sender, swapCounter, block.timestamp));

        // Transfer tokens from requester
        fromToken.transferFrom(msg.sender, address(this), amountIn);

        pendingSwaps[swapId] = PendingSwap({
            requester: msg.sender,
            amountIn: amountIn,
            fromToken: address(fromToken),
            toToken: address(toToken),
            recipient: recipient,
            priceChecker: priceChecker,
            priceCheckerData: priceCheckerData,
            createdAt: block.timestamp,
            settled: false,
            cancelled: false
        });

        swapIds.push(swapId);

        emit SwapRequested(swapId, msg.sender, address(fromToken), address(toToken), amountIn);

        // Auto-settle if configured
        if (shouldAutoSettle && autoSettlementDelay == 0) {
            _settleSwap(swapId, _calculateOutput(swapId));
        }
    }

    /// @notice Cancel a swap (matches IMilkman signature)
    function cancelSwap(
        address /* orderContract */,
        uint256 /* amountIn */,
        IERC20 /* fromToken */,
        IERC20 /* toToken */,
        address /* to */,
        address /* priceChecker */,
        bytes calldata /* priceCheckerData */
    ) external {
        // For testing, cancel the latest swap
        require(swapIds.length > 0, "No swaps");
        bytes32 swapId = swapIds[swapIds.length - 1];
        _cancelSwap(swapId);
    }

    /// @notice Get domain separator (matches IMilkman)
    function domainSeparator() external pure returns (bytes32) {
        return keccak256("MockMilkmanDomain");
    }

    /// @notice Compute order contract address (matches IMilkman)
    function computeOrderContract(
        address /* orderCreator */,
        uint256 /* amountIn */,
        IERC20 /* fromToken */,
        IERC20 /* toToken */,
        address /* to */,
        address /* priceChecker */,
        bytes calldata /* priceCheckerData */
    ) external pure returns (address) {
        // Return a deterministic address for testing
        return address(0xDEAD);
    }

    // ═══════════════════════════════════════════════════════════════════
    // TEST CONTROLS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Cancel swap by ID (test helper)
    function cancelSwapById(bytes32 swapId) external {
        _cancelSwap(swapId);
    }

    /// @notice Manually settle a pending swap
    function settleSwap(bytes32 swapId, uint256 amountOut) external {
        _settleSwap(swapId, amountOut);
    }

    /// @notice Settle with calculated output based on mock prices
    function settleSwapWithPrice(bytes32 swapId) external {
        uint256 output = _calculateOutput(swapId);
        _settleSwap(swapId, output);
    }

    /// @notice Settle all pending swaps
    function settleAllPending() external {
        for (uint256 i = 0; i < swapIds.length; i++) {
            bytes32 swapId = swapIds[i];
            PendingSwap storage swap = pendingSwaps[swapId];
            if (!swap.settled && !swap.cancelled) {
                _settleSwap(swapId, _calculateOutput(swapId));
            }
        }
    }

    /// @notice Get pending swap details
    function getSwap(bytes32 swapId) external view returns (PendingSwap memory) {
        return pendingSwaps[swapId];
    }

    /// @notice Get count of pending (unsettled, uncancelled) swaps
    function getPendingCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < swapIds.length; i++) {
            PendingSwap storage swap = pendingSwaps[swapIds[i]];
            if (!swap.settled && !swap.cancelled) {
                count++;
            }
        }
    }

    /// @notice Get latest swap ID
    function getLatestSwapId() external view returns (bytes32) {
        require(swapIds.length > 0, "No swaps");
        return swapIds[swapIds.length - 1];
    }

    /// @notice Fund contract with tokens for settlement
    function fundSettlementLiquidity(address token, uint256 amount) external {
        // Assumes MockERC20 with mint function
        (bool success, ) = token.call(abi.encodeWithSignature("mint(address,uint256)", address(this), amount));
        require(success, "MockMilkman: mint failed");
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    function _cancelSwap(bytes32 swapId) internal {
        PendingSwap storage swap = pendingSwaps[swapId];
        require(!swap.settled, "MockMilkman: already settled");
        require(!swap.cancelled, "MockMilkman: already cancelled");

        swap.cancelled = true;

        // Return tokens to requester
        IERC20(swap.fromToken).transfer(swap.requester, swap.amountIn);

        emit SwapCancelled(swapId);
    }

    function _settleSwap(bytes32 swapId, uint256 amountOut) internal {
        PendingSwap storage swap = pendingSwaps[swapId];
        require(!swap.settled, "MockMilkman: already settled");
        require(!swap.cancelled, "MockMilkman: cancelled");

        // Check price if configured to fail
        if (shouldFailPriceCheck) {
            revert("MockMilkman: price check failed");
        }

        swap.settled = true;

        // Transfer output tokens to recipient
        IERC20(swap.toToken).transfer(swap.recipient, amountOut);

        emit SwapSettled(swapId, amountOut);
    }

    function _calculateOutput(bytes32 swapId) internal view returns (uint256) {
        PendingSwap storage swap = pendingSwaps[swapId];

        uint256 price = mockPrices[swap.fromToken][swap.toToken];
        if (price == 0) {
            // Default 1:1 if no price set
            price = 1e18;
        }

        uint256 rawOutput = (swap.amountIn * price) / 1e18;
        return (rawOutput * outputMultiplier) / 1e18;
    }
}
