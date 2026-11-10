// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "./BaseTest.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { TwapOracle } from "../src/TwapOracle.sol";
import { FlashArbExecutor } from "../src/FlashArbExecutor.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @title SecurityFixes
/// @notice Regression tests for the fixes applied after the second audit round:
///           - M-1: `TwapOracle.update` is keeper-gated (closes the free DoS and
///                  the stranger-owned averaging window),
///           - M-2: `consult` reverts when the actual window exceeds `MAX_PERIOD`,
///           - L-2: `FlashArbExecutor` measures profit as its own balance delta,
///           - L-3: `AmmPair.mint` fails with an explicit `ZERO_RESERVE` error
///                  instead of an arithmetic panic,
///           - C-1(demo): `MockERC20.burn` only burns the caller's own balance.
contract SecurityFixesTest is BaseTest {
    TwapOracle internal oracle;
    FlashArbExecutor internal arb;
    AmmPair internal pairAB;
    AmmPair internal pairBC;
    AmmPair internal pairCA;

    address internal attacker = makeAddr("attacker");
    address internal profitRecipient = makeAddr("profitRecipient");

    function setUp() public override {
        super.setUp();
        // The test contract deploys the oracle, so the test contract is the keeper.
        oracle = new TwapOracle(address(factory));
        arb = new FlashArbExecutor(address(factory), address(this), profitRecipient);
        pairAB = _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        pairBC = _seedPair(address(tokenB), address(tokenC), 10_000e18, 10_000e18);
        pairCA = _seedPair(address(tokenA), address(tokenC), 10_000e18, 10_000e18);

        // BaseTest funds alice/bob/carol and this contract, but not the attacker.
        MockERC20(tokenA).mint(attacker, 1_000e18);
        MockERC20(tokenB).mint(attacker, 1_000e18);
        MockERC20(tokenC).mint(attacker, 1_000e18);
    }

    // ---------------------------------------------------------------------
    // M-1: update is keeper-gated
    // ---------------------------------------------------------------------

    function test_Update_StrangerCannotRecordAnObservation() public {
        vm.expectRevert("TwapOracle: FORBIDDEN");
        vm.prank(attacker);
        oracle.update(address(pairAB));

        (,, uint32 ts) = oracle.observations(address(pairAB));
        assertEq(ts, 0, "a stranger must not be able to create an observation");
    }

    /// @notice The exact scenario from `test_PermissionlessUpdateIsAFreeDenialOfService`,
    ///         replayed after the fix: ten rounds of hostile pokes can no longer hold
    ///         `elapsed` at zero, so consumers keep getting prices.
    function test_Update_KeeperGateEndsTheFreeDenialOfService() public {
        oracle.update(address(pairAB));

        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 3600);
            pairAB.sync();
            vm.expectRevert("TwapOracle: FORBIDDEN");
            vm.prank(attacker);
            oracle.update(address(pairAB));
        }

        uint256 price = oracle.consult(address(pairAB), 60);
        assertApproxEqRel(price, uint256(1) << 112, 0.01e18, "the window survived ten hostile rounds");
    }

    function test_Update_KeeperCanStillRecordObservations() public {
        oracle.update(address(pairAB));
        vm.warp(block.timestamp + 600);
        pairAB.sync();
        oracle.update(address(pairAB));

        (,, uint32 ts) = oracle.observations(address(pairAB));
        assertEq(ts, block.timestamp, "keeper updates must keep working");
    }

    function test_SetKeeper_OnlyKeeper() public {
        vm.expectRevert("TwapOracle: FORBIDDEN");
        vm.prank(attacker);
        oracle.setKeeper(attacker);

        oracle.setKeeper(address(0xBEEF));
        assertEq(oracle.keeper(), address(0xBEEF));
    }

    function test_SetKeeper_RevertsOnZero() public {
        vm.expectRevert("TwapOracle: ZERO_ADDRESS");
        oracle.setKeeper(address(0));
    }

    // ---------------------------------------------------------------------
    // M-2: the actual window is bounded by MAX_PERIOD
    // ---------------------------------------------------------------------

    /// @notice A consumer asking for 60 seconds must not silently receive a 30-day
    ///         average once the accumulator is staler than MAX_PERIOD.
    function test_Consult_RevertsWhenWindowExceedsMaxPeriod() public {
        oracle.update(address(pairAB));
        vm.warp(block.timestamp + 30 days);
        pairAB.sync();

        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StaleWindow.selector, address(pairAB), uint32(30 days)));
        oracle.consult(address(pairAB), 60);

        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StaleWindow.selector, address(pairAB), uint32(30 days)));
        oracle.consult(address(pairAB), 7 days);
    }

    /// @notice A window of exactly MAX_PERIOD is still accepted: the bound is inclusive.
    function test_Consult_WindowOfExactlyMaxPeriodIsAccepted() public {
        oracle.update(address(pairAB));
        vm.warp(block.timestamp + 7 days);
        pairAB.sync();

        uint256 price = oracle.consult(address(pairAB), 60);
        assertApproxEqRel(price, uint256(1) << 112, 0.01e18, "an exactly-MAX_PERIOD window must still read");
    }

    // ---------------------------------------------------------------------
    // L-2: profit is the executor's own balance delta
    // ---------------------------------------------------------------------

    function test_Execute_ExcludesPreExistingBalanceFromProfit() public {
        // A stranger sends tokenA to the executor by mistake.
        vm.prank(attacker);
        tokenA.transfer(address(arb), 777e18);

        // A genuine dislocation so the arb is profitable.
        tokenA.mint(alice, 2_000e18);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(2_000e18, 0, _path(address(tokenA), address(tokenC)), alice, block.timestamp);
        vm.stopPrank();

        uint256 recipientBefore = tokenA.balanceOf(profitRecipient);
        uint256 profit = arb.execute(address(pairAB), address(pairBC), address(pairCA), address(tokenB), 500e18);

        assertGt(profit, 0, "the arb must still be profitable");
        assertLt(profit, 777e18, "the stray 777 must not be reported as arb profit");
        assertEq(tokenA.balanceOf(profitRecipient) - recipientBefore, profit, "recipient gets exactly the profit");
        assertEq(tokenA.balanceOf(address(arb)), 777e18, "stray tokens stay in the executor");
    }

    // ---------------------------------------------------------------------
    // L-3: zero reserve fails with an explicit error, not a panic
    // ---------------------------------------------------------------------

    function test_Mint_ZeroReserveFailsWithExplicitError() public {
        // Drive the token0 side to zero. Only the pair itself may burn from its own balance
        // (post-C-1 `MockERC20.burn` is self-service), which models a rebase-down token.
        // The balance read must happen BEFORE the prank: vm.prank applies to the very next
        // call, and a staticcall would silently consume it.
        uint256 pairBalance = tokenA.balanceOf(address(pairAB));
        vm.prank(address(pairAB));
        tokenA.burn(address(pairAB), pairBalance);
        pairAB.sync();

        (uint112 r0,,) = pairAB.getReserves();
        assertEq(r0, 0, "reserve is zeroed");

        tokenA.mint(bob, 1_000e18);
        tokenB.mint(bob, 1_000e18);
        vm.startPrank(bob);
        tokenA.transfer(address(pairAB), 1_000e18);
        tokenB.transfer(address(pairAB), 1_000e18);
        vm.expectRevert("AmmPair: ZERO_RESERVE");
        pairAB.mint(bob);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // C-1(demo): MockERC20.burn only burns the caller's own balance
    // ---------------------------------------------------------------------

    function test_MockBurn_StrangerCannotBurnSomeoneElsesBalance() public {
        uint256 pairBalance = tokenA.balanceOf(address(pairAB));
        assertGt(pairBalance, 0);

        vm.expectRevert("MockERC20: FORBIDDEN");
        vm.prank(attacker);
        tokenA.burn(address(pairAB), pairBalance);

        assertEq(tokenA.balanceOf(address(pairAB)), pairBalance, "the pool balance must be untouched");
    }

    function test_MockBurn_OwnerCanBurnOwnBalance() public {
        uint256 pairBalance = tokenA.balanceOf(address(pairAB));
        vm.prank(address(pairAB));
        tokenA.burn(address(pairAB), 1e18);
        assertEq(tokenA.balanceOf(address(pairAB)), pairBalance - 1e18);
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
