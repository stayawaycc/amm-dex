// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "./BaseTest.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { FlashArbExecutor } from "../src/FlashArbExecutor.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { IAmmPair } from "../src/interfaces/IAmmPair.sol";

/// @notice Tests for the capital-free triangular arbitrage executor.
/// @dev The economic premise: three pools A/B, B/C, A/C imply three prices. When they disagree,
///      borrowing one leg and cycling through the other two is profitable, and the flash swap
///      means the arbitrageur needs no starting capital. Each test isolates one part of that.
contract FlashArbTest is BaseTest {
    FlashArbExecutor internal arb;

    AmmPair internal pairAB;
    AmmPair internal pairBC;
    AmmPair internal pairCA;

    address internal profitRecipient = makeAddr("profitRecipient");

    function setUp() public override {
        super.setUp();
        arb = new FlashArbExecutor(address(factory), address(this), profitRecipient);

        // A balanced triangle. Implied cross rates are consistent, so there is no edge yet.
        pairAB = _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        pairBC = _seedPair(address(tokenB), address(tokenC), 10_000e18, 10_000e18);
        pairCA = _seedPair(address(tokenA), address(tokenC), 10_000e18, 10_000e18);
    }

    // ---------------------------------------------------------------------
    // Construction / admin
    // ---------------------------------------------------------------------

    function test_Constructor_SetsImmutables() public view {
        assertEq(arb.factory(), address(factory));
        assertEq(arb.profitRecipient(), profitRecipient);
        assertEq(arb.owner(), address(this));
    }

    function test_Constructor_RevertsOnZeroFactory() public {
        vm.expectRevert("FlashArb: ZERO_ADDRESS");
        new FlashArbExecutor(address(0), address(this), profitRecipient);
    }

    function test_Constructor_RevertsOnZeroRecipient() public {
        vm.expectRevert("FlashArb: ZERO_ADDRESS");
        new FlashArbExecutor(address(factory), address(this), address(0));
    }

    function test_SetMinProfit_OnlyOwner() public {
        arb.setMinProfit(1e18);
        assertEq(arb.minProfit(), 1e18);

        vm.prank(alice);
        vm.expectRevert();
        arb.setMinProfit(2e18);
    }

    function test_SetProfitRecipient_OnlyOwner() public {
        arb.setProfitRecipient(alice);
        assertEq(arb.profitRecipient(), alice);

        vm.prank(alice);
        vm.expectRevert();
        arb.setProfitRecipient(bob);
    }

    function test_SetProfitRecipient_RevertsOnZero() public {
        vm.expectRevert("FlashArb: ZERO_ADDRESS");
        arb.setProfitRecipient(address(0));
    }

    // ---------------------------------------------------------------------
    // Guards
    // ---------------------------------------------------------------------

    function test_Execute_RevertsOnUnregisteredPair() public {
        AmmPair rogue = new AmmPair();
        rogue.initialize(address(tokenA), address(tokenB));

        vm.expectRevert(abi.encodeWithSelector(FlashArbExecutor.UnauthorizedPair.selector, address(rogue)));
        arb.execute(address(rogue), address(pairBC), address(pairCA), address(tokenB), 100e18);
    }

    function test_AmmCall_RevertsWhenNotActivePair() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FlashArbExecutor.NotActivePair.selector, alice));
        arb.ammCall(alice, 0, 0, abi.encode(address(pairBC), address(pairCA), address(tokenA)));
    }

    /// @notice A balanced triangle has no edge, so the callback must abort.
    function test_Execute_RevertsWithoutDislocation() public {
        vm.expectRevert(FlashArbExecutor.Unprofitable.selector);
        arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), 100e18);
    }

    function test_Execute_RevertsOnExcessiveBorrow() public {
        vm.expectRevert("AmmPair: INSUFFICIENT_LIQUIDITY");
        arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), 20_000e18);
    }

    function test_Execute_RevertsWhenTriangleIsBroken() public {
        // pairCA does not contain tokenB, so the second leg cannot complete the cycle.
        vm.expectRevert();
        arb.execute(address(pairAB), address(pairCA), address(pairBC), address(tokenB), 100e18);
    }

    // ---------------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------------

    /// @notice Creates a genuine triangular dislocation and verifies the loan is repaid in full
    ///         before profit is extracted.
    function test_Execute_ProfitsAndRepaysLender() public {
        _createDislocation();

        (uint112 r0Before, uint112 r1Before,) = pairAB.getReserves();
        uint256 recipientBefore = tokenA.balanceOf(profitRecipient);

        uint256 profit = arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), 500e18);

        assertGt(profit, 0, "arbitrage must be profitable");

        // The lender's invariant must never decrease: it took its fee out of the profit.
        (uint112 r0After, uint112 r1After,) = pairAB.getReserves();
        assertGe(uint256(r0After) * r1After, uint256(r0Before) * r1Before, "lender pool must not lose value");

        assertEq(tokenA.balanceOf(profitRecipient) - recipientBefore, profit);
        assertEq(tokenA.balanceOf(address(arb)), 0, "executor must not retain profit");
    }

    /// @notice After a successful arb the executor holds nothing of any token.
    function test_Execute_LeavesNoResidualBalance() public {
        _createDislocation();
        arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), 500e18);

        assertEq(tokenA.balanceOf(address(arb)), 0);
        assertEq(tokenB.balanceOf(address(arb)), 0);
        assertEq(tokenC.balanceOf(address(arb)), 0);
    }

    /// @notice The arb closes the dislocation: running it twice must fail the second time.
    function test_Execute_SecondRunIsUnprofitable() public {
        _createDislocation();
        arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), 500e18);

        vm.expectRevert();
        arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), 500e18);
    }

    function test_Execute_RespectsMinProfit() public {
        _createDislocation();
        // Require an unreachable profit: the arb must refuse to settle.
        arb.setMinProfit(1_000_000e18);
        vm.expectRevert();
        arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), 500e18);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    /// @notice For any borrow size the lender must be repaid; profit may be zero but never negative.
    function testFuzz_LenderAlwaysRepaid(uint96 borrowAmount) public {
        _createDislocation();
        uint256 borrow = bound(uint256(borrowAmount), 1e15, 4_000e18);

        (uint112 r0Before, uint112 r1Before,) = pairAB.getReserves();

        try arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), borrow) {
            (uint112 r0After, uint112 r1After,) = pairAB.getReserves();
            assertGe(uint256(r0After) * r1After, uint256(r0Before) * r1Before, "lender lost value");
        } catch {
            // Reverting is always acceptable: the pair stays untouched.
            (uint112 r0After, uint112 r1After,) = pairAB.getReserves();
            assertEq(uint256(r0After) * r1After, uint256(r0Before) * r1Before, "revert must not move reserves");
        }
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Creates a genuine triangular dislocation by dumping tokenA into pairCA.
    ///
    ///      After the dump, pool CA holds an excess of A and a shortage of C, so A is cheap
    ///      there: selling C into CA returns an outsized amount of A. That is exactly the edge
    ///      the B -> C -> A cycle monetises, and it is the same imbalance an arbitrageur would
    ///      find on a live venue after a large directional trade.
    function _createDislocation() internal {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(2_000e18, 0, _path(address(tokenA), address(tokenC)), alice, block.timestamp);
        vm.stopPrank();
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }
}
