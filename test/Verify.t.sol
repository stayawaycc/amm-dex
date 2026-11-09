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
    /// @dev This is the exact claim the Critical label rests on. If the answer is "no, they must
    ///      hold for the full period", then C-1 is the sustained-manipulation case already
    ///      documented in the README, not a zero-cost oracle break.
    function test_ResetDoesNotRemoveTheHoldingRequirement() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 10_000e18);
        tokenB.transfer(address(pair), 10_000e18);
        pair.mint(address(this));

        uint32 period = 600;

        // Baseline observation.
        oracle.update(address(pair));
        vm.warp(block.timestamp + period);
        pair.sync();

        // Attacker crashes the price.
        vm.startPrank(attacker);
        tokenA.transfer(address(pair), 5_000_000e18);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 out = (uint256(5_000_000e18) * 997 * r1) / (uint256(r0) * 1000 + uint256(5_000_000e18) * 997);
        pair.swap(0, out, attacker, new bytes(0));
        vm.stopPrank();

        uint256 crushedSpot = _spot0(pair);

        // *** The attack: reset the observation immediately after the crash ***
        vm.prank(attacker);
        oracle.update(address(pair));

        // Attempt to read the manipulated price RIGHT NOW, with zero holding time.
        // If C-1 were a zero-cost break, this would return the crushed price.
        vm.expectRevert();
        oracle.consult(address(pair), period);

        // The read is refused, not poisoned. Now hold the price for the full period and retry.
        vm.warp(block.timestamp + period);
        pair.sync();

        uint256 published = oracle.consult(address(pair), period);

        emit log_named_uint("crushed spot   ", crushedSpot);
        emit log_named_uint("published TWAP ", published);

        // The attacker only succeeds after paying the full holding cost.
        assertApproxEqRel(published, crushedSpot, 0.01e18, "price is manipulated after holding");
    }

    // =====================================================================
    // F1b: is the free DoS real?
    // =====================================================================

    /// @notice The strongest claim in the report: an attacker can keep `consult` reverting forever
    ///         at zero cost. Verify it independently.
    function test_PermissionlessUpdateIsAFreeDenialOfService() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 10_000e18);
        tokenB.transfer(address(pair), 10_000e18);
        pair.mint(address(this));

        oracle.update(address(pair));

        // Ten rounds of legitimate activity, each followed by an attacker reset.
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 3600);
            pair.sync();
            vm.prank(attacker);
            oracle.update(address(pair));
        }

        // Every consumer is now permanently locked out: elapsed is always ~0.
        vm.expectRevert();
        oracle.consult(address(pair), 60);

        emit log_string("confirmed: a permissionless update() can hold elapsed at 0 indefinitely");
    }

    // =====================================================================
    // C-2: is MockERC20.burn really unguarded, and does it reach the demo deployment?
    // =====================================================================

    function test_BurnIsUnguardedOnTheDeployedDemoToken() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 10_000e18);
        tokenB.transfer(address(pair), 10_000e18);
        pair.mint(address(this));

        uint256 pairBalance = tokenA.balanceOf(address(pair));
        assertEq(pairBalance, 10_000e18);

        // Anyone can burn anyone's balance.
        vm.prank(attacker);
        tokenA.burn(address(pair), pairBalance);

        assertEq(tokenA.balanceOf(address(pair)), 0, "attacker wiped the pair balance");

        (uint112 r0,,) = pair.getReserves();
        emit log_named_uint("reserve0 still claims", r0);
        emit log_named_uint("actual balance       ", tokenA.balanceOf(address(pair)));

        assertGt(r0, 0, "reserve is now a lie");
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

        uint256 shortPeriod = oracle.consult(address(pair), 60);
        uint256 longPeriod = oracle.consult(address(pair), 7 days);

        emit log_named_uint("consult(60s)  ", shortPeriod);
        emit log_named_uint("consult(7days)", longPeriod);

        assertEq(shortPeriod, longPeriod, "period does not change the window: MAX_PERIOD is advisory only");
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _spot0(AmmPair pair) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return (uint256(r1) << 112) / r0;
    }

    receive() external payable { }
}

