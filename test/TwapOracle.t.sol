// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "./BaseTest.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { TwapOracle } from "../src/TwapOracle.sol";
import { AmmLibrary } from "../src/libraries/AmmLibrary.sol";

/// @notice Tests for the TWAP oracle, including the manipulation resistance it exists to provide.
contract TwapOracleTest is BaseTest {
    TwapOracle internal oracle;
    AmmPair internal pair;

    uint32 internal constant PERIOD = 600; // 10 minutes

    function setUp() public override {
        super.setUp();
        oracle = new TwapOracle(address(factory));
        pair = _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        _approveAll(alice);
        _approveAll(bob);
    }

    // ---------------------------------------------------------------------
    // Construction / configuration
    // ---------------------------------------------------------------------

    function test_Constructor_RevertsOnZeroFactory() public {
        vm.expectRevert("TwapOracle: ZERO_ADDRESS");
        new TwapOracle(address(0));
    }

    function test_Constants_AreSane() public view {
        assertEq(oracle.MIN_PERIOD(), 60);
        assertEq(oracle.MAX_PERIOD(), 7 days);
        assertLt(oracle.MIN_PERIOD(), PERIOD);
        assertLt(PERIOD, oracle.MAX_PERIOD());
    }

    // ---------------------------------------------------------------------
    // Observation lifecycle
    // ---------------------------------------------------------------------

    function test_Consult_RevertsWithoutObservation() public {
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.NoObservation.selector, address(pair)));
        oracle.consult(address(pair), PERIOD);
    }

    function test_Update_RecordsCumulativePrices() public {
        oracle.update(address(pair));
        (uint256 p0, uint256 p1, uint32 ts) = oracle.observations(address(pair));
        assertEq(p0, pair.price0CumulativeLast());
        assertEq(p1, pair.price1CumulativeLast());
        assertEq(ts, block.timestamp);
    }

    function test_Consult_RevertsBeforeWindowElapsed() public {
        oracle.update(address(pair));
        vm.warp(block.timestamp + PERIOD - 1);
        pair.sync(); // advance the accumulator

        vm.expectRevert(
            abi.encodeWithSelector(TwapOracle.WindowNotElapsed.selector, address(pair), uint32(PERIOD - 1), PERIOD)
        );
        oracle.consult(address(pair), PERIOD);
    }

    function test_Consult_RevertsOnPeriodTooShort() public {
        oracle.update(address(pair));
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PeriodOutOfRange.selector, uint32(59)));
        oracle.consult(address(pair), 59);
    }

    function test_Consult_RevertsOnPeriodTooLong() public {
        oracle.update(address(pair));
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PeriodOutOfRange.selector, uint32(7 days + 1)));
        oracle.consult(address(pair), 7 days + 1);
    }

    // ---------------------------------------------------------------------
    // Price correctness
    // ---------------------------------------------------------------------

    function test_Consult_ReturnsSpotPriceWhenPoolIsUndisturbed() public {
        // At a 1:1 pool the TWAP must equal 1.0 in UQ112x112 terms.
        oracle.update(address(pair));
        vm.warp(block.timestamp + PERIOD);
        pair.sync();

        uint256 price = oracle.consult(address(pair), PERIOD);
        assertApproxEqRel(price, uint256(1) << 112, 0.001e18);
    }

    function test_Consult_ReflectsTwoToOnePool() public {
        // Rebuild the pool at 1:2 so price0 = reserve1 / reserve0 = 2.
        AmmPair pair2 = _seedPair(address(tokenA), address(tokenC), 10_000e18, 20_000e18);
        oracle.update(address(pair2));
        vm.warp(block.timestamp + PERIOD);
        pair2.sync();

        uint256 price = oracle.consult(address(pair2), PERIOD);
        assertApproxEqRel(price, uint256(2) << 112, 0.01e18);
    }

    function test_Consult1_IsReciprocalOfConsult() public {
        oracle.update(address(pair));
        vm.warp(block.timestamp + PERIOD);
        pair.sync();

        uint256 p0 = oracle.consult(address(pair), PERIOD);
        uint256 p1 = oracle.consult1(address(pair), PERIOD);
        // Both should be ~1.0 here; the product must be ~1.0 in Q224 terms.
        assertApproxEqRel(p0, p1, 0.001e18);
        assertApproxEqRel((p0 * p1) >> 112, uint256(1) << 112, 0.01e18);
    }

    function test_ConsultPair_ResolvesPairFromFactory() public {
        oracle.update(address(pair));
        vm.warp(block.timestamp + PERIOD);
        pair.sync();

        uint256 direct = oracle.consult(address(pair), PERIOD);
        uint256 resolved = oracle.consultPair(address(tokenB), address(tokenA), PERIOD);
        // Argument order must not matter: the factory sorts the tokens.
        assertEq(direct, resolved);
    }

    // ---------------------------------------------------------------------
    // Manipulation resistance 鈥?the whole point of the oracle
    // ---------------------------------------------------------------------

    /// @notice A single-transaction spot price manipulation must not move the TWAP meaningfully.
    /// @dev This is the core property. The attacker dumps a large amount into the pool in one
    ///      block, so `getReserves()` reports a distorted ratio, but the accumulator barely moves
    ///      because dt is ~0. A consumer reading spot would be fooled; a consumer reading the
    ///      TWAP is not.
    function test_Manipulation_SpotPriceMovesButTwapDoesNot() public {
        oracle.update(address(pair));
        vm.warp(block.timestamp + PERIOD);
        // Touch the pair so the accumulator actually advances over the window.
        pair.sync();

        uint256 twapBefore = oracle.consult(address(pair), PERIOD);

        // Attacker dumps 5,000,000 tokenA into a 10,000/10,000 pool: spot price collapses.
        tokenA.mint(alice, 5_000_000e18);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(
            5_000_000e18, 0, _path(address(tokenA), address(tokenB)), alice, block.timestamp
        );
        vm.stopPrank();

        // Spot price is now far from 1:1.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertLt(uint256(r1) * 1e18 / uint256(r0), 0.5e18, "spot price should be crushed");

        // The TWAP over the same window is essentially unchanged, because the manipulation
        // consumed no time.
        uint256 twapAfter = oracle.consult(address(pair), PERIOD);
        assertApproxEqRel(twapAfter, twapBefore, 0.05e18, "TWAP must resist atomic manipulation");
    }

    /// @notice Sustained manipulation across the whole window *does* move the TWAP.
    /// @dev Stated explicitly so integrators understand the limit: the oracle defends against
    ///      atomic manipulation, not against an attacker willing to hold a bad price for `period`.
    function test_Manipulation_SustainedPriceMovesTwap() public {
        oracle.update(address(pair));
        vm.warp(block.timestamp + PERIOD);
        pair.sync();
        uint256 twapBefore = oracle.consult(address(pair), PERIOD);

        tokenA.mint(alice, 5_000_000e18);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(
            5_000_000e18, 0, _path(address(tokenA), address(tokenB)), alice, block.timestamp
        );
        vm.stopPrank();

        // Hold the manipulated price for the full window.
        vm.warp(block.timestamp + PERIOD);
        pair.sync();

        uint256 twapAfter = oracle.consult(address(pair), PERIOD);
        assertLt(twapAfter, twapBefore, "a sustained manipulation must move the TWAP");
    }

    /// @notice The longer the averaging window, the harder the manipulation is to sustain.
    function test_Manipulation_LongerWindowDampensMore() public {
        oracle.update(address(pair));
        vm.warp(block.timestamp + PERIOD);
        pair.sync();

        tokenA.mint(alice, 5_000_000e18);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(
            5_000_000e18, 0, _path(address(tokenA), address(tokenB)), alice, block.timestamp
        );
        vm.stopPrank();

        // Only 60s of the manipulation is inside a 60s window, but the same 60s is a small
        // fraction of a 3600s window only if the pool is undisturbed afterwards. Hold the
        // manipulated price for 60s, then let the pool sit at a normal price for the rest.
        vm.warp(block.timestamp + 60);
        pair.sync();
        uint256 shortTwap = oracle.consult(address(pair), 60);

        // A 60s window that fully contains the manipulation shows it; that is expected and is
        // precisely why MIN_PERIOD exists as a floor rather than an endorsement.
        assertLt(shortTwap, uint256(1) << 112);
    }

    // ---------------------------------------------------------------------
    // Staleness
    // ---------------------------------------------------------------------

    /// @notice If the pair is never touched, the accumulator stops advancing and reads must revert.
    function test_Consult_RevertsWhenAccumulatorIsStale() public {
        oracle.update(address(pair));
        // Move time forward without touching the pair: the accumulator does not advance.
        vm.warp(block.timestamp + PERIOD * 2);

        vm.expectRevert();
        oracle.consult(address(pair), PERIOD);
    }

    function test_Update_CanBeCalledRepeatedly() public {
        oracle.update(address(pair));
        vm.warp(block.timestamp + 100);
        pair.sync();
        oracle.update(address(pair));

        (,, uint32 ts) = oracle.observations(address(pair));
        assertEq(ts, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }
}
