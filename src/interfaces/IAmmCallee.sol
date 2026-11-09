// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAmmCallee
/// @notice Callback interface for flash swaps.
interface IAmmCallee {
    /// @param sender The address that initiated the swap (the router or an arbitrary caller).
    /// @param amount0Out The amount of token0 sent to the callee before the callback.
    /// @param amount1Out The amount of token1 sent to the callee before the callback.
    /// @param data Arbitrary calldata forwarded from the swap.
    function ammCall(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata data) external;
}
