// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IChainlinkAggregatorV3} from "custom/integrations/morpho/interfaces/IChainlinkAutomation.sol";

/**
 * @title MockChainlinkFeed
 * @notice Configurable mock of Chainlink price feed for testing
 * @dev Supports price history, staleness simulation, and price spikes
 */
contract MockChainlinkFeed is IChainlinkAggregatorV3 {
    // ═══════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════

    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    uint8 public immutable override decimals;
    string public override description;
    uint256 public constant override version = 1;

    // Price history for TWAP testing
    int256[] public priceHistory;
    uint256[] public timestampHistory;

    // Configurable behavior
    bool public isStale;
    bool public shouldRevert;
    bool public returnZeroPrice;
    bool public returnNegativePrice;

    // ═══════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    constructor(uint8 _decimals, string memory _description, int256 _initialPrice) {
        decimals = _decimals;
        description = _description;
        price = _initialPrice;
        updatedAt = block.timestamp;
        roundId = 1;

        priceHistory.push(_initialPrice);
        timestampHistory.push(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
        roundId++;

        priceHistory.push(_price);
        timestampHistory.push(block.timestamp);
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function setStale(bool _isStale) external {
        isStale = _isStale;
        if (_isStale) {
            // Set updatedAt to 3 hours ago (beyond typical 2h staleness threshold)
            updatedAt = block.timestamp - 3 hours;
        } else {
            updatedAt = block.timestamp;
        }
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setReturnZeroPrice(bool _returnZero) external {
        returnZeroPrice = _returnZero;
    }

    function setReturnNegativePrice(bool _returnNegative) external {
        returnNegativePrice = _returnNegative;
    }

    // ═══════════════════════════════════════════════════════════════════
    // IChainlinkAggregatorV3 IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 _roundId,
            int256 _answer,
            uint256 _startedAt,
            uint256 _updatedAt,
            uint80 _answeredInRound
        )
    {
        require(!shouldRevert, "MockChainlinkFeed: reverted");

        int256 _price = price;
        if (returnZeroPrice) {
            _price = 0;
        } else if (returnNegativePrice) {
            _price = -1;
        }

        return (roundId, _price, updatedAt, updatedAt, roundId);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        require(!shouldRevert, "MockChainlinkFeed: reverted");
        require(_roundId > 0 && _roundId <= roundId, "No data for round");

        uint256 idx = _roundId - 1;
        if (idx >= priceHistory.length) {
            return (roundId, price, updatedAt, updatedAt, roundId);
        }

        return (
            _roundId,
            priceHistory[idx],
            timestampHistory[idx],
            timestampHistory[idx],
            _roundId
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // TEST HELPERS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Advance to next round with new price
    function advanceRound(int256 newPrice) external {
        roundId++;
        price = newPrice;
        updatedAt = block.timestamp;

        priceHistory.push(newPrice);
        timestampHistory.push(block.timestamp);
    }

    /// @notice Simulate sudden price spike (for circuit breaker testing)
    function simulatePriceSpike(int256 spikeAmount) external {
        int256 newPrice = price + spikeAmount;
        roundId++;
        price = newPrice;
        updatedAt = block.timestamp;

        priceHistory.push(newPrice);
        timestampHistory.push(block.timestamp);
    }

    /// @notice Apply percentage change to price
    /// @param bpsChange Change in basis points (e.g., 1000 = +10%, -500 = -5%)
    function applyPercentageChange(int256 bpsChange) external {
        int256 change = (price * bpsChange) / 10000;
        int256 newPrice = price + change;
        require(newPrice > 0, "Price would go negative");

        roundId++;
        price = newPrice;
        updatedAt = block.timestamp;

        priceHistory.push(newPrice);
        timestampHistory.push(block.timestamp);
    }

    /// @notice Get price history length
    function getHistoryLength() external view returns (uint256) {
        return priceHistory.length;
    }

    /// @notice Get price at specific index
    function getPriceAt(uint256 index) external view returns (int256, uint256) {
        require(index < priceHistory.length, "Index out of bounds");
        return (priceHistory[index], timestampHistory[index]);
    }

    /// @notice Calculate simple moving average of last N prices
    function getSMA(uint256 periods) external view returns (int256) {
        require(periods > 0, "Periods must be > 0");
        uint256 len = priceHistory.length;
        uint256 count = periods > len ? len : periods;

        int256 sum = 0;
        for (uint256 i = len - count; i < len; i++) {
            sum += priceHistory[i];
        }

        return sum / int256(count);
    }

    /// @notice Reset price history
    function resetHistory() external {
        delete priceHistory;
        delete timestampHistory;

        priceHistory.push(price);
        timestampHistory.push(block.timestamp);
    }

    /// @notice Reset all state
    function reset(int256 _initialPrice) external {
        price = _initialPrice;
        updatedAt = block.timestamp;
        roundId = 1;
        isStale = false;
        shouldRevert = false;
        returnZeroPrice = false;
        returnNegativePrice = false;

        delete priceHistory;
        delete timestampHistory;
        priceHistory.push(_initialPrice);
        timestampHistory.push(block.timestamp);
    }
}
