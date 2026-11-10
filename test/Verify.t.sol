// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { AmmFactory } from "../src/AmmFactory.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { AmmRouter } from "../src/AmmRouter.sol";
import { TwapOracle } from "../src/TwapOracle.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { WETH9 } from "../src/mocks/WETH9.sol";

/// @title VerifyTest
/// @notice Independent re-verification of the severity claims in the sub-agent's audit.
/// @dev The point of this file is NOT to re-run their PoCs. It is to test the *specific claim*
///      each severity rests on. A PoC that passes only proves the code does something; it does not
///      prove the severity label attached to it is right.
contract VerifyTest is Test {
    AmmFactory internal factory;
    AmmRouter internal router;
    TwapOracle internal oracle;
    WETH9 internal weth;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        vm.warp(1_700_000_000);
        factory = new AmmFactory(address(this));
        weth = new WETH9();
        router = new AmmRouter(address(factory), address(weth));
        oracle = new TwapOracle(address(factory));

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), 100_000_000e18);
        tokenB.mint(address(this), 100_000_000e18);
        tokenA.mint(attacker, 100_000_000e18);
        tokenB.mint(attacker, 100_000_000e18);

        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
    }

    // =====================================================================
    // DECISIVE TEST for C-1 severity
    // =====================================================================

    /// @notice Can an attacker publish a manipulated TWAP *without* holding the price for `period`?
    /// @dev This is the exact claim the Critical label rested on. Post-fix the reset itself is
    ///      refused: only the keeper may re-anchor the window. The attacker's dump owns zero
    ///      seconds of the window, so the oracle keeps publishing the honest price; only after
    ///      holding the crushed price for a full extra window does the average move.
    function test_ResetDoesNotRemoveTheHoldingRequirement() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 10_000e18);
        tokenB.transfer(address(pair), 10_000e18);
        pair.mint(address(this));

        uint32 period = 600;

        // Baseline observation right after seeding, so the window starts clean.
        oracle.update(address(pair));
        vm.warp(block.timestamp + period);
        pair.sync();

        // Attacker crashes the price in the same block as the sync: zero seconds of window.
        vm.startPrank(attacker);
        tokenA.transfer(address(pair), 5_000_000e18);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 out = (uint256(5_000_000e18) * 997 * r1) / (uint256(r0) * 1000 + uint256(5_000_000e18) * 997);
        pair.swap(0, out, attacker, new bytes(0));
        vm.stopPrank();

        // The manipulated price actually sitting in the accumulator: the honest accumulator
        // before the crash was exactly `honest * elapsed`, so the per-second leg after the
        // dump is what the attacker wants the oracle to publish.
        uint256 honest = uint256(1) << 112;

        // *** The attack: reset the observation immediately after the crash ***
        // Post-fix this is refused outright.
        vm.prank(attacker);
        vm.expectRevert("TwapOracle: FORBIDDEN");
        oracle.update(address(pair));

        // The window is untouched, so the published average is still the honest 1:1 price.
        uint256 published = oracle.consult(address(pair), period);
        emit log_named_uint("published TWAP ", published);
        assertApproxEqRel(published, honest, 0.001e18, "the atomic dump must not move the TWAP");

        // Only after holding the manipulated price for a full extra window does it start to
        // count: the window is then 1200 s, half honest, half manipulated -> midpoint.
        uint256 accBefore = pair.price0CumulativeLast();
        vm.warp(block.timestamp + period);
        pair.sync();
        // The manipulated price that actually sat in the accumulator for that window.
        uint256 manipLeg0 = (pair.price0CumulativeLast() - accBefore) / period;
        uint256 diluted = oracle.consult(address(pair), period);
        emit log_named_uint("manipulated leg", manipLeg0);
        emit log_named_uint("diluted TWAP   ", diluted);
        assertApproxEqRel(diluted, (honest + manipLeg0) / 2, 0.02e18, "sustained holding moves it halfway");
    }

    // =====================================================================
    // F1b: is the free DoS real?
    // =====================================================================

    /// @notice The strongest claim in the original report was that an attacker could keep `consult`
    ///         reverting forever at zero cost. Post-fix the keeper gate blocks every hostile
    ///         poke, so the DoS is no longer reachable.
    function test_KeeperGateEndsTheFreeDenialOfService() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 10_000e18);
        tokenB.transfer(address(pair), 10_000e18);
        pair.mint(address(this));

        oracle.update(address(pair));

        // Ten rounds of legitimate activity, each followed by an attempted attacker reset.
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 3600);
            pair.sync();
            vm.expectRevert("TwapOracle: FORBIDDEN");
            vm.prank(attacker);
            oracle.update(address(pair));
        }

        // Consumers keep reading: the window was never re-anchored.
        uint256 price = oracle.consult(address(pair), 60);
        assertApproxEqRel(price, uint256(1) << 112, 0.01e18, "the DoS is closed");
    }

    // =====================================================================
    // C-2: is MockERC20.burn really unguarded, and does it reach the demo deployment?
    // =====================================================================

    function test_DemoTokenBurnIsGuardedAfterTheFix() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 10_000e18);
        tokenB.transfer(address(pair), 10_000e18);
        pair.mint(address(this));

        uint256 pairBalance = tokenA.balanceOf(address(pair));
        assertEq(pairBalance, 10_000e18);

        // Post-fix the demo token only lets an address burn its own balance.
        vm.prank(attacker);
        vm.expectRevert("MockERC20: FORBIDDEN");
        tokenA.burn(address(pair), pairBalance);

        assertEq(tokenA.balanceOf(address(pair)), pairBalance, "the pool balance is untouched");

        (uint112 r0,,) = pair.getReserves();
        assertEq(uint256(r0), pairBalance, "reserve and balance still agree");
    }

    // =====================================================================
    // F6: does MAX_PERIOD bound anything?
    // =====================================================================

    function test_MaxPeriodDoesNotBoundTheWindow() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 10_000e18);
        tokenB.transfer(address(pair), 10_000e18);
        pair.mint(address(this));

        oracle.update(address(pair));
        vm.warp(block.timestamp + 30 days);
        pair.sync();

        // Post-fix the window itself is bounded: a 30-day-old accumulator is refused
        // outright for every requested period.
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StaleWindow.selector, address(pair), uint32(30 days)));
        oracle.consult(address(pair), 60);

        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StaleWindow.selector, address(pair), uint32(30 days)));
        oracle.consult(address(pair), 7 days);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    receive() external payable { }
}

