// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title UQ112x112
/// @notice Fixed point library for encoding a uint112 as a UQ112x112 binary fraction.
/// @dev The upper 112 bits hold the integer part, the lower 112 bits hold the fraction.
///      Division truncates towards zero, which is exactly the behaviour the AMM needs:
///      a price can only ever be under-reported, never over-reported.
library UQ112x112 {
    uint224 internal constant Q112 = 2 ** 112;

    /// @dev Encodes a uint112 as a UQ112x112 value.
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112;
    }

    /// @dev Divides a UQ112x112 by a uint112, returning a UQ112x112.
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}
