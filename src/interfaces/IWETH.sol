// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IWETH
/// @notice Minimal interface for the canonical WETH9 contract.
interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 amount) external;

    function transfer(address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}
