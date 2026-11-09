// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "./BaseTest.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { AmmRouter } from "../src/AmmRouter.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { WETH9 } from "../src/mocks/WETH9.sol";
import { IAmmPair } from "../src/interfaces/IAmmPair.sol";
import { AmmLibrary } from "../src/libraries/AmmLibrary.sol";

/// @notice Unit tests for the router: liquidity provision, multi-hop swaps and ETH wrapping.
contract AmmRouterTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _approveAll(alice);
        _approveAll(bob);
    }

    // ---------------------------------------------------------------------
    // addLiquidity
    // ---------------------------------------------------------------------

    function test_AddLiquidity_CreatesPairOnFirstCall() public {
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            router.addLiquidity(address(tokenA), address(tokenB), 1000e18, 1000e18, 0, 0, alice, block.timestamp);

        assertEq(amountA, 1000e18);
        assertEq(amountB, 1000e18);
        assertGt(liquidity, 0);

        address pair = factory.getPair(address(tokenA), address(tokenB));
        assertTrue(pair != address(0));
        assertEq(AmmPair(pair).balanceOf(alice), liquidity);
    }

    function test_AddLiquidity_UsesOptimalRatio() public {
        // Seed at 1:2 so the second deposit is rebalanced to that ratio.
        _seedPair(address(tokenA), address(tokenB), 1000e18, 2000e18);

        (uint256 amountA, uint256 amountB,) =
            router.addLiquidity(address(tokenA), address(tokenB), 100e18, 300e18, 0, 0, alice, block.timestamp);

        // 100 A needs only 200 B at the 1:2 ratio, so B is the limiting side at 300 -> A = 150.
        // The A side binds first here: 100 A -> 200 B <= 300 B.
        assertEq(amountA, 100e18);
        assertEq(amountB, 200e18);
    }

    function test_AddLiquidity_RevertsOnSlippage() public {
        _seedPair(address(tokenA), address(tokenB), 1000e18, 2000e18);

        vm.expectRevert("AmmRouter: INSUFFICIENT_B_AMOUNT");
        router.addLiquidity(address(tokenA), address(tokenB), 100e18, 300e18, 0, 250e18, alice, block.timestamp);
    }

    function test_AddLiquidity_RevertsAfterDeadline() public {
        vm.expectRevert("AmmRouter: EXPIRED");
        router.addLiquidity(address(tokenA), address(tokenB), 100e18, 100e18, 0, 0, alice, block.timestamp - 1);
    }

    // ---------------------------------------------------------------------
    // removeLiquidity
    // ---------------------------------------------------------------------

    function test_RemoveLiquidity_ReturnsUnderlying() public {
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 1000e18, 1000e18, 0, 0, address(this), block.timestamp
        );

        // The router pulls LP tokens with transferFrom, so the holder must approve it.
        address pair = factory.getPair(address(tokenA), address(tokenB));
        AmmPair(pair).approve(address(router), type(uint256).max);

        uint256 aBefore = tokenA.balanceOf(address(this));
        (uint256 amountA, uint256 amountB) =
            router.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, address(this), block.timestamp);

        assertApproxEqAbs(amountA, 1000e18, 1e6);
        assertApproxEqAbs(amountB, 1000e18, 1e6);
        assertEq(tokenA.balanceOf(address(this)) - aBefore, amountA);
    }

    function test_RemoveLiquidity_RevertsOnSlippage() public {
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 1000e18, 1000e18, 0, 0, address(this), block.timestamp
        );

        address pair = factory.getPair(address(tokenA), address(tokenB));
        AmmPair(pair).approve(address(router), type(uint256).max);

        vm.expectRevert("AmmRouter: INSUFFICIENT_A_AMOUNT");
        router.removeLiquidity(address(tokenA), address(tokenB), liquidity, 2000e18, 0, address(this), block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------

    function test_SwapExactTokensForTokens_SingleHop() public {
        router.addLiquidity(address(tokenA), address(tokenB), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);

        uint256 bBefore = tokenB.balanceOf(bob);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(100e18, 0, _path(address(tokenA), address(tokenB)), bob, block.timestamp);

        assertEq(amounts[0], 100e18);
        assertLt(amounts[1], 100e18, "fee must reduce output");
        assertGt(amounts[1], 98e18, "output should be close to input at a 1:1 pool");
        assertEq(tokenB.balanceOf(bob) - bBefore, amounts[1]);
    }

    function test_SwapExactTokensForTokens_RevertsOnSlippage() public {
        router.addLiquidity(address(tokenA), address(tokenB), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);

        vm.expectRevert("AmmRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        router.swapExactTokensForTokens(100e18, 100e18, _path(address(tokenA), address(tokenB)), bob, block.timestamp);
    }

    function test_SwapExactTokensForTokens_MultiHop() public {
        router.addLiquidity(address(tokenA), address(tokenB), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);
        router.addLiquidity(address(tokenB), address(tokenC), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);

        uint256 cBefore = tokenC.balanceOf(bob);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            100e18, 0, _path3(address(tokenA), address(tokenB), address(tokenC)), bob, block.timestamp
        );

        assertEq(amounts.length, 3);
        assertEq(amounts[0], 100e18);
        // Two hops means the fee is applied twice.
        assertLt(amounts[2], amounts[1]);
        assertEq(tokenC.balanceOf(bob) - cBefore, amounts[2]);
    }

    function test_SwapTokensForExactTokens_DeliversExactAmount() public {
        router.addLiquidity(address(tokenA), address(tokenB), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);

        uint256 aBefore = tokenA.balanceOf(address(this));
        uint256 bBefore = tokenB.balanceOf(bob);
        uint256[] memory amounts = router.swapTokensForExactTokens(
            100e18, type(uint256).max, _path(address(tokenA), address(tokenB)), bob, block.timestamp
        );

        assertEq(tokenB.balanceOf(bob) - bBefore, 100e18);
        assertGt(amounts[0], 100e18, "must pay more than the output due to fees");
        assertEq(aBefore - tokenA.balanceOf(address(this)), amounts[0]);
    }

    function test_SwapTokensForExactTokens_RevertsWhenInputTooHigh() public {
        router.addLiquidity(address(tokenA), address(tokenB), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);

        vm.expectRevert("AmmRouter: EXCESSIVE_INPUT_AMOUNT");
        router.swapTokensForExactTokens(100e18, 100e18, _path(address(tokenA), address(tokenB)), bob, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // ETH paths
    // ---------------------------------------------------------------------

    function test_AddLiquidityETH_WrapsAndRefundsExcess() public {
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        router.addLiquidityETH{ value: 10 ether }(address(tokenA), 10_000e18, 0, 0, alice, block.timestamp);

        // All 10 ETH is consumed because the token side is large enough to match it.
        assertEq(ethBefore - alice.balance, 10 ether);
        address pair = factory.getPair(address(tokenA), address(weth));
        assertGt(AmmPair(pair).balanceOf(alice), 0);
    }

    function test_AddLiquidityETH_RefundsUnusedETH() public {
        // Seed the pair at a 1:1 ratio in ETH terms, then deposit a wildly imbalanced amount.
        _seedPair(address(tokenA), address(weth), 10_000e18, 10 ether);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        router.addLiquidityETH{ value: 100 ether }(address(tokenA), 1000e18, 0, 0, alice, block.timestamp);

        // Only ~1 ETH is needed for 1000 tokenA, so the rest must be refunded.
        uint256 spent = ethBefore - alice.balance;
        assertLt(spent, 2 ether, "excess ETH must be refunded");
        assertGt(spent, 0);
    }

    function test_SwapExactETHForTokens() public {
        router.addLiquidityETH{ value: 100 ether }(address(tokenA), 100_000e18, 0, 0, alice, block.timestamp);

        uint256 aBefore = tokenA.balanceOf(bob);
        uint256[] memory amounts = router.swapExactETHForTokens{ value: 1 ether }(
            0, _path(address(weth), address(tokenA)), bob, block.timestamp
        );

        assertEq(amounts[0], 1 ether);
        assertGt(tokenA.balanceOf(bob) - aBefore, 0);
    }

    function test_SwapExactTokensForETH() public {
        router.addLiquidityETH{ value: 100 ether }(address(tokenA), 100_000e18, 0, 0, alice, block.timestamp);

        uint256 ethBefore = bob.balance;
        uint256[] memory amounts =
            router.swapExactTokensForETH(1000e18, 0, _path(address(tokenA), address(weth)), bob, block.timestamp);

        assertGt(amounts[1], 0);
        assertEq(bob.balance - ethBefore, amounts[1]);
    }

    function test_RemoveLiquidityETH_Unwraps() public {
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        (,, uint256 liquidity) =
            router.addLiquidityETH{ value: 10 ether }(address(tokenA), 10_000e18, 0, 0, alice, block.timestamp);

        AmmPair(factory.getPair(address(tokenA), address(weth))).approve(address(router), type(uint256).max);

        (uint256 amountToken, uint256 amountETH) =
            router.removeLiquidityETH(address(tokenA), liquidity, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(amountToken, 0);
        assertGt(amountETH, 0);
        // Alice paid 10 ETH in, got amountETH back; the delta must match the reported amount.
        assertEq(ethBefore - alice.balance, 10 ether - amountETH);
    }

    function test_Receive_RevertsForNonWETH() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok,) = address(router).call{ value: 1 ether }("");
        assertFalse(ok, "direct ETH transfers must be rejected");
    }

    // ---------------------------------------------------------------------
    // Quotes
    // ---------------------------------------------------------------------

    function test_GetAmountsOut_MatchesSwapOutput() public {
        router.addLiquidity(address(tokenA), address(tokenB), 10_000e18, 20_000e18, 0, 0, alice, block.timestamp);

        uint256[] memory quoted = router.getAmountsOut(100e18, _path(address(tokenA), address(tokenB)));
        uint256[] memory actual =
            router.swapExactTokensForTokens(100e18, 0, _path(address(tokenA), address(tokenB)), bob, block.timestamp);

        assertEq(quoted[1], actual[1], "quote must match execution");
    }

    function test_Quote_RevertsOnEmptyReserves() public {
        vm.expectRevert("AmmRouter: INSUFFICIENT_LIQUIDITY");
        router.quote(1, 0, 1);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    /// @notice Swapping then swapping back must always return less than the original input.
    function testFuzz_SwapRoundTripLosesValue(uint96 amountIn) public {
        router.addLiquidity(address(tokenA), address(tokenB), 100_000e18, 100_000e18, 0, 0, alice, block.timestamp);
        uint256 input = bound(uint256(amountIn), 1e12, 1000e18);

        uint256[] memory out =
            router.swapExactTokensForTokens(input, 0, _path(address(tokenA), address(tokenB)), bob, block.timestamp);
        uint256[] memory back =
            router.swapExactTokensForTokens(out[1], 0, _path(address(tokenB), address(tokenA)), bob, block.timestamp);

        assertLt(back[1], input, "round trip must lose value to fees");
    }

    /// @notice The router must never leave a token balance behind after a completed swap.
    function testFuzz_RouterHoldsNoBalanceAfterSwap(uint96 amountIn) public {
        router.addLiquidity(address(tokenA), address(tokenB), 100_000e18, 100_000e18, 0, 0, alice, block.timestamp);
        uint256 input = bound(uint256(amountIn), 1e12, 1000e18);

        router.swapExactTokensForTokens(input, 0, _path(address(tokenA), address(tokenB)), bob, block.timestamp);

        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }

    function _path3(address a, address b, address c) internal pure returns (address[] memory path) {
        path = new address[](3);
        path[0] = a;
        path[1] = b;
        path[2] = c;
    }
}
