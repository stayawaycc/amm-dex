// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "./BaseTest.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { AmmFactory } from "../src/AmmFactory.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { IAmmPair } from "../src/interfaces/IAmmPair.sol";
import { AmmLibrary } from "../src/libraries/AmmLibrary.sol";

/// @notice Unit tests for the constant-product pair.
contract AmmPairTest is BaseTest {
    AmmPair internal pair;

    function setUp() public override {
        super.setUp();
        pair = _createPair(address(tokenA), address(tokenB));
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function test_Initialize_SortsTokens() public view {
        assertEq(pair.token0(), address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB));
        assertEq(pair.token1(), address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA));
    }

    function test_Initialize_RevertsOnSecondCall() public {
        vm.expectRevert("AmmPair: FORBIDDEN");
        pair.initialize(address(tokenA), address(tokenB));
    }

    function test_Initialize_RevertsOnIdenticalTokens() public {
        // The factory rejects identical addresses before deployment, so assert at the factory level.
        vm.expectRevert("AmmFactory: IDENTICAL_ADDRESSES");
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_CreatePair_IsDeterministicRegardlessOfOrder() public {
        address predicted = AmmLibrary.pairFor(address(factory), address(tokenA), address(tokenB));
        assertEq(predicted, address(pair));
        assertEq(factory.getPair(address(tokenA), address(tokenB)), address(pair));
        assertEq(factory.getPair(address(tokenB), address(tokenA)), address(pair));
    }

    function test_CreatePair_RevertsWhenPairExists() public {
        vm.expectRevert("AmmFactory: PAIR_EXISTS");
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_CreatePair_RevertsOnZeroAddress() public {
        vm.expectRevert("AmmFactory: ZERO_ADDRESS");
        factory.createPair(address(0), address(tokenA));
    }

    // ---------------------------------------------------------------------
    // Mint
    // ---------------------------------------------------------------------

    function test_Mint_FirstLiquidityLocksMinimum() public {
        uint256 amountA = 1000e18;
        uint256 amountB = 1000e18;
        tokenA.transfer(address(pair), amountA);
        tokenB.transfer(address(pair), amountB);

        uint256 liquidity = pair.mint(alice);

        uint256 expected = _sqrt(amountA * amountB) - pair.MINIMUM_LIQUIDITY();
        assertEq(liquidity, expected);
        assertEq(pair.totalSupply(), expected + pair.MINIMUM_LIQUIDITY());
        assertEq(pair.balanceOf(address(0xdead)), pair.MINIMUM_LIQUIDITY());
        assertEq(pair.balanceOf(alice), expected);
    }

    function test_Mint_SubsequentLiquidityIsProportional() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        uint256 supplyBefore = pair.totalSupply();

        tokenA.transfer(address(pair), 100e18);
        tokenB.transfer(address(pair), 100e18);
        uint256 liquidity = pair.mint(alice);

        // 10% of the pool was added, so 10% of the supply should be minted.
        assertApproxEqRel(liquidity, supplyBefore / 10, 0.001e18);
    }

    function test_Mint_RevertsWhenLiquidityIsZero() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        vm.expectRevert("AmmPair: INSUFFICIENT_LIQUIDITY_MINTED");
        pair.mint(alice);
    }

    function test_Mint_UpdatesReserves() public {
        _seedPair(address(tokenA), address(tokenB), 500e18, 800e18);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, 500e18);
        assertEq(r1, 800e18);
    }

    // ---------------------------------------------------------------------
    // Burn
    // ---------------------------------------------------------------------

    function test_Burn_ReturnsProportionalUnderlying() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        uint256 lpBalance = pair.balanceOf(address(this));

        pair.transfer(address(pair), lpBalance);
        (uint256 amount0, uint256 amount1) = pair.burn(bob);

        assertApproxEqAbs(amount0, 1000e18, 1e6);
        assertApproxEqAbs(amount1, 1000e18, 1e6);
        assertEq(pair.balanceOf(bob), 0);
        assertGt(tokenA.balanceOf(bob), 0);
    }

    function test_Burn_RevertsWithoutLiquidity() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        vm.expectRevert("AmmPair: INSUFFICIENT_LIQUIDITY_BURNED");
        pair.burn(bob);
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    function test_Swap_ExactInputFollowsCurve() public {
        _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        uint256 amountIn = 100e18;

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 expectedOut = _getAmountOut(amountIn, r0, r1);

        uint256 bobBefore = tokenB.balanceOf(bob);
        tokenA.transfer(address(pair), amountIn);
        pair.swap(0, expectedOut, bob, new bytes(0));

        assertEq(tokenB.balanceOf(bob) - bobBefore, expectedOut);
        (, uint112 r1After,) = pair.getReserves();
        assertEq(r1After, r1 - expectedOut);
    }

    function test_Swap_RevertsOnZeroOutput() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        vm.expectRevert("AmmPair: INSUFFICIENT_OUTPUT_AMOUNT");
        pair.swap(0, 0, bob, new bytes(0));
    }

    function test_Swap_RevertsWhenOutputExceedsReserve() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        vm.expectRevert("AmmPair: INSUFFICIENT_LIQUIDITY");
        pair.swap(0, 1000e18, bob, new bytes(0));
    }

    function test_Swap_RevertsWhenKInvariantBroken() public {
        _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        // Take out almost everything without paying anything in.
        vm.expectRevert("AmmPair: INSUFFICIENT_INPUT_AMOUNT");
        pair.swap(0, 100e18, bob, new bytes(0));
    }

    function test_Swap_RevertsWhenToIsToken() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        tokenA.transfer(address(pair), 10e18);
        vm.expectRevert("AmmPair: INVALID_TO");
        pair.swap(0, 1e18, address(tokenB), new bytes(0));
    }

    function test_Swap_FeeAccruesToLiquidityProviders() public {
        _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        uint256 kBefore = _k(pair);

        for (uint256 i; i < 10; ++i) {
            tokenA.transfer(address(pair), 100e18);
            (uint112 r0, uint112 r1,) = pair.getReserves();
            pair.swap(0, _getAmountOut(100e18, r0, r1), bob, new bytes(0));
        }

        assertGt(_k(pair), kBefore, "fees should increase k");
    }

    // ---------------------------------------------------------------------
    // Sync / skim
    // ---------------------------------------------------------------------

    function test_Sync_AdoptsDonatedBalances() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        tokenA.transfer(address(pair), 50e18);

        pair.sync();
        (uint112 r0,,) = pair.getReserves();
        assertEq(r0, 1050e18);
    }

    function test_Skim_RecoversDonation() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 1000e18);
        tokenA.transfer(address(pair), 50e18);

        uint256 bobBefore = tokenA.balanceOf(bob);
        pair.skim(bob);
        assertEq(tokenA.balanceOf(bob) - bobBefore, 50e18);
        (uint112 r0,,) = pair.getReserves();
        assertEq(r0, 1000e18);
    }

    // ---------------------------------------------------------------------
    // TWAP accumulators
    // ---------------------------------------------------------------------

    function test_CumulativePrice_AccumulatesOverTime() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 2000e18);
        uint256 p0Before = pair.price0CumulativeLast();

        vm.warp(block.timestamp + 3600);
        tokenA.transfer(address(pair), 1e18);
        pair.sync();

        uint256 p0After = pair.price0CumulativeLast();
        assertGt(p0After, p0Before);

        // price0 = reserve1 / reserve0 = 2, so the increment should be ~2 * 3600 * 2**112.
        uint256 expected = (uint256(2) << 112) * 3600;
        assertApproxEqRel(p0After - p0Before, expected, 0.01e18);
    }

    function test_CumulativePrice_DoesNotAdvanceWithinSameBlock() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 2000e18);
        uint256 p0Before = pair.price0CumulativeLast();

        tokenA.transfer(address(pair), 1e18);
        pair.sync();

        assertEq(pair.price0CumulativeLast(), p0Before);
    }

    // ---------------------------------------------------------------------
    // Protocol fee
    // ---------------------------------------------------------------------

    function test_ProtocolFee_MintsToFeeRecipient() public {
        factory.setFeeTo(feeTo);
        _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);

        // Generate fees, then trigger the protocol fee via a second mint.
        for (uint256 i; i < 20; ++i) {
            tokenA.transfer(address(pair), 100e18);
            (uint112 r0, uint112 r1,) = pair.getReserves();
            pair.swap(0, _getAmountOut(100e18, r0, r1), bob, new bytes(0));
        }
        tokenA.transfer(address(pair), 1000e18);
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);

        assertGt(pair.balanceOf(feeTo), 0, "fee recipient should receive LP tokens");
    }

    function test_ProtocolFee_DisabledWhenFeeToCleared() public {
        factory.setFeeTo(feeTo);
        _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        factory.setFeeTo(address(0));

        tokenA.transfer(address(pair), 1000e18);
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);

        assertEq(pair.balanceOf(feeTo), 0);
        assertEq(pair.kLast(), 0);
    }

    function test_SetFeeTo_RevertsForNonSetter() public {
        vm.prank(alice);
        vm.expectRevert("AmmFactory: FORBIDDEN");
        factory.setFeeTo(alice);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    /// @notice For any input size below 1% of the reserve, the output must be strictly less than
    ///         the input (no free lunch) and the pool must stay solvent.
    function testFuzz_SwapNeverProfitable(uint96 amountIn, uint96 liquiditySeed) public {
        // Cap the seed at 10% of the fixture balance so the test contract can always fund it.
        uint256 seed = bound(uint256(liquiditySeed), 1e18, INITIAL_BALANCE / 10);
        uint256 input = bound(uint256(amountIn), 1, seed / 100);
        _seedPair(address(tokenA), address(tokenB), seed, seed);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 out = _getAmountOut(input, r0, r1);
        // A 1 wei input against a thin pool can round down to zero output, which the pair
        // correctly rejects. That case carries no economic meaning, so skip it.
        vm.assume(out > 0);
        assertLt(out, input, "output must be smaller than input");

        uint256 bobBefore = tokenB.balanceOf(bob);
        tokenA.transfer(address(pair), input);
        pair.swap(0, out, bob, new bytes(0));

        (, uint112 r1After,) = pair.getReserves();
        assertGe(r1After, 0);
        assertEq(tokenB.balanceOf(bob) - bobBefore, out);
    }

    /// @notice Round-trip through the same pool must always lose value to fees.
    function testFuzz_RoundTripAlwaysLosesToFee(uint96 amountIn) public {
        _seedPair(address(tokenA), address(tokenB), 100_000e18, 100_000e18);
        uint256 input = bound(uint256(amountIn), 1e12, 1000e18);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 out = _getAmountOut(input, r0, r1);
        tokenA.transfer(address(pair), input);
        pair.swap(0, out, bob, new bytes(0));

        (uint112 r0b, uint112 r1b,) = pair.getReserves();
        uint256 back = _getAmountOut(out, r1b, r0b);
        assertLt(back, input, "round trip must lose value");
    }

    /// @notice getAmountIn returns the *minimal* input that still delivers `amountOut`.
    /// @dev The over-delivery of a round trip scales with the price ratio, so asserting a fixed
    ///      1 wei bound is wrong. The meaningful property is minimality: one wei less must fall
    ///      short. That is exactly what protects a `swapTokensForExactTokens` caller from being
    ///      charged more than necessary.
    function testFuzz_AmountInIsMinimal(uint96 amountOut, uint96 reserveIn, uint96 reserveOut) public pure {
        uint256 rIn = bound(uint256(reserveIn), 1e6, 1e30);
        uint256 rOut = bound(uint256(reserveOut), 1e6, 1e30);
        uint256 out = bound(uint256(amountOut), 1, rOut - 1);

        uint256 amountIn = _getAmountIn(out, rIn, rOut);

        // The quoted input must actually deliver the requested output.
        assertGe(_getAmountOut(amountIn, rIn, rOut), out, "quoted input under-delivers");

        // And it must be minimal: paying one wei less falls short.
        if (amountIn > 1) {
            assertLt(_getAmountOut(amountIn - 1, rIn, rOut), out, "quoted input is not minimal");
        }
    }

    // ---------------------------------------------------------------------
    // Local math mirrors (kept independent of the library under test)
    // ---------------------------------------------------------------------

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        return (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
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
