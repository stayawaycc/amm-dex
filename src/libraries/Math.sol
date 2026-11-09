// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Math
/// @notice Minimal integer helpers used by the AMM core.
library Math {
    /// @notice Returns the smaller of two values.
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Babylonian square root, rounded down.
    /// @dev Used only once per pair, when the first liquidity is minted.
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
