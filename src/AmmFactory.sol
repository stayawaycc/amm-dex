// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAmmFactory } from "./interfaces/IAmmFactory.sol";
import { AmmPair } from "./AmmPair.sol";

/// @title AmmFactory
/// @notice Deploys one AmmPair per unordered token pair and keeps a canonical index.
/// @dev Pair addresses are deterministic: CREATE2 with salt = keccak256(abi.encodePacked(token0, token1)).
///      Because the tokens are sorted first, `createPair(A, B)` and `createPair(B, A)` resolve to
///      the same address, so the mapping can never hold two pools for the same market.
contract AmmFactory is IAmmFactory {
    /// @notice Protocol fee recipient. When set to address(0) the protocol fee is disabled.
    address public override feeTo;

    /// @notice Address allowed to change `feeTo` and `feeToSetter`.
    address public override feeToSetter;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    constructor(address feeToSetter_) {
        require(feeToSetter_ != address(0), "AmmFactory: ZERO_ADDRESS");
        feeToSetter = feeToSetter_;
    }

    /// @inheritdoc IAmmFactory
    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    /// @inheritdoc IAmmFactory
    function pairCodeHash() external pure override returns (bytes32) {
        return keccak256(type(AmmPair).creationCode);
    }

    /// @inheritdoc IAmmFactory
    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, "AmmFactory: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "AmmFactory: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "AmmFactory: PAIR_EXISTS");

        bytes memory bytecode = type(AmmPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(pair != address(0), "AmmFactory: CREATE2_FAILED");

        AmmPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /// @inheritdoc IAmmFactory
    function setFeeTo(address feeTo_) external override {
        require(msg.sender == feeToSetter, "AmmFactory: FORBIDDEN");
        feeTo = feeTo_;
    }

    /// @inheritdoc IAmmFactory
    function setFeeToSetter(address feeToSetter_) external override {
        require(msg.sender == feeToSetter, "AmmFactory: FORBIDDEN");
        require(feeToSetter_ != address(0), "AmmFactory: ZERO_ADDRESS");
        feeToSetter = feeToSetter_;
    }
}
