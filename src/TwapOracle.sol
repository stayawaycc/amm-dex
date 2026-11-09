// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAmmPair } from "./interfaces/IAmmPair.sol";
import { IAmmFactory } from "./interfaces/IAmmFactory.sol";
import { AmmLibrary } from "./libraries/AmmLibrary.sol";

/// @title TwapOracle
/// @notice Time-weighted average price reader on top of AmmPair's cumulative price accumulators.
/// @dev Why this exists
///      A spot reserve ratio can be moved inside a single transaction with a flash loan, so any
///      contract that consumes `getReserves()` as a price is trivially manipulable. AmmPair keeps
///      two monotonically increasing accumulators (`price0CumulativeLast`) which encode
///      sum(price_i * dt_i). Averaging over a window [t0, t1] therefore requires only the two
///      accumulator snapshots and the elapsed seconds — no capital, no atomic manipulation.
///
///      Limitations, stated explicitly so integrators do not over-trust it:
///      - The window is bounded by how recently the pair was last touched. A caller must observe
///        at least `period` seconds of accumulator growth, so the very first observation after a
///        long idle period is only as fresh as the last swap/mint/burn.
///      - A well-funded attacker can hold a manipulated price across the whole window, which
///        costs them the arbitrage loss for `period` seconds. Longer windows are safer.
///      - Cumulative prices wrap around 2**256. Because the accumulator grows by
///        price * dt and price is capped by the uint112 reserve ratio, a wrap requires
///        astronomically long windows; the subtraction below is still done with wrapping
///        semantics for correctness.
contract TwapOracle {
    struct Observation {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint32 timestamp;
    }

    /// @notice Minimum window a consumer is allowed to request, in seconds.
    uint32 public constant MIN_PERIOD = 60;

    /// @notice Maximum window, so that a stale accumulator cannot be queried indefinitely.
    uint32 public constant MAX_PERIOD = 7 days;

    address public immutable factory;

    /// @notice Last snapshot per pair, written by `update`.
    mapping(address => Observation) public observations;

    event Updated(address indexed pair, uint256 price0Cumulative, uint256 price1Cumulative, uint32 timestamp);

    error PeriodOutOfRange(uint32 period);
    error NoObservation(address pair);
    error WindowNotElapsed(address pair, uint32 elapsed, uint32 period);

    constructor(address factory_) {
        require(factory_ != address(0), "TwapOracle: ZERO_ADDRESS");
        factory = factory_;
    }

    /// @notice Records the current cumulative prices of a pair.
    /// @dev Must be called at least once per `period` by whoever relies on the average, and the
    ///      first call must happen at least `period` seconds before the first read.
    function update(address pair) external returns (Observation memory obs) {
        (uint256 price0, uint256 price1, uint32 ts) = _snapshot(pair);
        obs = Observation({ price0Cumulative: price0, price1Cumulative: price1, timestamp: ts });
        observations[pair] = obs;
        emit Updated(pair, price0, price1, ts);
    }

    /// @notice Returns the average price of token0 denominated in token1 over the last `period`.
    /// @return price UQ112x112-scaled average, i.e. token1 per token0 * 2**112.
    /// @dev The average is divided by the *actual* elapsed window, not by `period`. If the pair
    ///      was touched later than `period` seconds ago the result is still a true average over
    ///      that longer window, rather than a value scaled up by elapsed/period. This makes the
    ///      oracle safe to read without pinning the accumulator to an exact block.
    function consult(address pair, uint32 period) external view returns (uint256 price) {
        price = _consult(pair, period, true);
    }

    /// @notice Returns the average price of token1 denominated in token0 over the last `period`.
    function consult1(address pair, uint32 period) external view returns (uint256 price) {
        price = _consult(pair, period, false);
    }

    /// @notice Convenience wrapper that resolves the pair from the factory first.
    function consultPair(address tokenA, address tokenB, uint32 period) external view returns (uint256 price) {
        price = _consult(AmmLibrary.pairFor(factory, tokenA, tokenB), period, true);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _snapshot(address pair) internal view returns (uint256 price0, uint256 price1, uint32 ts) {
        price0 = IAmmPair(pair).price0CumulativeLast();
        price1 = IAmmPair(pair).price1CumulativeLast();
        (,, uint32 lastUpdate) = IAmmPair(pair).getReserves();
        ts = lastUpdate;
    }

    function _consult(address pair, uint32 period, bool zeroForOne) internal view returns (uint256 price) {
        if (period < MIN_PERIOD || period > MAX_PERIOD) revert PeriodOutOfRange(period);

        Observation memory obs = observations[pair];
        if (obs.timestamp == 0) revert NoObservation(pair);

        (uint256 price0Now, uint256 price1Now, uint32 tsNow) = _snapshot(pair);
        // The accumulator only advances when the pair is touched, so the effective end of the
        // window is min(now, lastPairUpdate).
        uint32 end = tsNow < uint32(block.timestamp) ? tsNow : uint32(block.timestamp);
        uint32 elapsed = end - obs.timestamp;
        if (elapsed < period) revert WindowNotElapsed(pair, elapsed, period);

        unchecked {
            if (zeroForOne) {
                price = (price0Now - obs.price0Cumulative) / elapsed;
            } else {
                price = (price1Now - obs.price1Cumulative) / elapsed;
            }
        }
    }
}
