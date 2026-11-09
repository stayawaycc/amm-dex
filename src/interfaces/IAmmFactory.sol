// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAmmFactory
/// @notice Deploys and indexes one AmmPair per unique token pair.
interface IAmmFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairIndex);

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);

    function allPairs(uint256 index) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address feeTo_) external;

    function setFeeToSetter(address feeToSetter_) external;

    /// @notice The keccak256 hash of the AmmPair creation code, used for off-chain address derivation.
    function pairCodeHash() external pure returns (bytes32);
}
