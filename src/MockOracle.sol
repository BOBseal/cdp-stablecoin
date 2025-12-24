// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ChainlinkInterfaces.sol";

/// @notice Mock aggregator implementing a subset of Chainlink's `AggregatorV3Interface`.
/// Returns `answer` scaled according to `decimals()`; this mock will store prices as ints.
contract MockOracle is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _answer;
    uint80 private _roundId;

    event PriceUpdated(int256 oldPrice, int256 newPrice);

    constructor(uint8 decimals_, int256 initialAnswer) {
        _decimals = decimals_;
        _answer = initialAnswer;
        _roundId = 1;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "MockOracle";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _answer, block.timestamp, block.timestamp, _roundId);
    }

    function setPrice(int256 newAnswer) external {
        emit PriceUpdated(_answer, newAnswer);
        _roundId++;
        _answer = newAnswer;
    }
}
