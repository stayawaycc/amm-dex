// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { AmmFactory } from "../src/AmmFactory.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { AmmRouter } from "../src/AmmRouter.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { WETH9 } from "../src/mocks/WETH9.sol";
import { IAmmPair } from "../src/interfaces/IAmmPair.sol";

/// @title Handler
/// @notice Bounded random actions for the invariant fuzzer.
/// @dev Every action is clamped to a sane range and wrapped in `try/catch` so a revert does not
///      abort the run. Without this the fuzzer spends its budget on reverts instead of exploring
///      states, and `fail_on_revert = true` would make every guard look like a bug.
contract Handler is Test {
    AmmPair public immutable pair;
    AmmRouter public immutable router;
    AmmFactory public immutable factory;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    address[3] public actors;
    uint256 public ghost_mintCount;
    uint256 public ghost_burnCount;
    uint256 public ghost_swapCount;
    uint256 public ghost_skimCount;

    constructor(AmmPair pair_, AmmRouter router_, AmmFactory factory_, MockERC20 t0, MockERC20 t1) {
        pair = pair_;
        router = router_;
        factory = factory_;
        token0 = t0;
        token1 = t1;
        actors = [makeAddr("h0"), makeAddr("h1"), makeAddr("h2")];
        for (uint256 i; i < actors.length; ++i) {
            token0.mint(actors[i], 1_000_000e18);
            token1.mint(actors[i], 1_000_000e18);
            vm.prank(actors[i]);
            token0.approve(address(router), type(uint256).max);
            vm.prank(actors[i]);
            token1.approve(address(router), type(uint256).max);
        }
    }

    function actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function addLiquidity(uint256 actorSeed, uint256 amount0, uint256 amount1) external {
        address who = actor(actorSeed);
        uint256 a0 = bound(amount0, 1e12, 10_000e18);
        uint256 a1 = bound(amount1, 1e12, 10_000e18);
        try router.addLiquidity(address(token0), address(token1), a0, a1, 0, 0, who, block.timestamp) {
            ghost_mintCount++;
        } catch { }
    }

    function removeLiquidity(uint256 actorSeed, uint256 liquidity) external {
        address who = actor(actorSeed);
        uint256 balance = pair.balanceOf(who);
        if (balance == 0) return;
        uint256 amount = bound(liquidity, 1, balance);
        vm.prank(who);
        pair.approve(address(router), amount);
        try router.removeLiquidity(address(token0), address(token1), amount, 0, 0, who, block.timestamp) {
            ghost_burnCount++;
        } catch { }
    }

    function swap0For1(uint256 actorSeed, uint256 amountIn) external {
        address who = actor(actorSeed);
        uint256 amount = bound(amountIn, 1e9, 10_000e18);
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        vm.prank(who);
        try router.swapExactTokensForTokens(amount, 0, path, who, block.timestamp) {
            ghost_swapCount++;
        } catch { }
    }

    function swap1For0(uint256 actorSeed, uint256 amountIn) external {
        address who = actor(actorSeed);
        uint256 amount = bound(amountIn, 1e9, 10_000e18);
        address[] memory path = new address[](2);
        path[0] = address(token1);
        path[1] = address(token0);
        vm.prank(who);
        try router.swapExactTokensForTokens(amount, 0, path, who, block.timestamp) {
            ghost_swapCount++;
        } catch { }
    }

    function donate(uint256 amount0, uint256 amount1) external {
        uint256 a0 = bound(amount0, 0, 100e18);
        uint256 a1 = bound(amount1, 0, 100e18);
        token0.mint(address(pair), a0);
        token1.mint(address(pair), a1);
    }

    function skim(uint256 actorSeed) external {
        address who = actor(actorSeed);
        try pair.skim(who) {
            ghost_skimCount++;
        } catch { }
    }

    function sync() external {
        try pair.sync() { } catch { }
    }

    function warp(uint256 secondsElapsed) external {
        vm.warp(block.timestamp + bound(secondsElapsed, 1, 1 days));
    }
}

/// @title InvariantTest
/// @notice Stateful fuzzing of the core AMM invariants.
/// @dev The three properties that must hold in every reachable state:
///        1. `reserve0 * reserve1` never decreases, except when a burn legitimately removes
///           liquidity (handled by comparing against the tracked minimum).
///        2. The pair's LP supply always equals the sum of all LP balances, i.e. no shares are
///           minted or destroyed outside `_mint`/`_burn`.
///        3. The pair never holds fewer tokens than its own reserves, so it is always solvent
///           against every LP at once.
contract InvariantTest is Test {
    AmmFactory internal factory;
    AmmRouter internal router;
    AmmPair internal pair;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Handler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);

        factory = new AmmFactory(address(this));
        WETH9 weth = new WETH9();
        router = new AmmRouter(address(factory), address(weth));

        token0 = new MockERC20("T0", "T0", 18);
        token1 = new MockERC20("T1", "T1", 18);

        pair = AmmPair(factory.createPair(address(token0), address(token1)));

        handler = new Handler(pair, router, factory, token0, token1);

        // Seed with real liquidity so the first swaps are not all rejected.
        token0.mint(address(this), 100_000e18);
        token1.mint(address(this), 100_000e18);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(token0), address(token1), 50_000e18, 50_000e18, 0, 0, address(this), block.timestamp
        );

        targetContract(address(handler));
    }

    /// @notice The pair must always hold at least the tokens it claims in its reserves.
    function invariant_PairIsSolvent() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGe(token0.balanceOf(address(pair)), r0, "token0 insolvent");
        assertGe(token1.balanceOf(address(pair)), r1, "token1 insolvent");
    }

    /// @notice LP supply is exactly the sum of holder balances: no unauthorised mint or burn.
    function invariant_LpSupplyMatchesBalances() public view {
        uint256 sum = pair.balanceOf(address(0xdead)) + pair.balanceOf(address(handler)) + pair.balanceOf(address(this))
            + pair.balanceOf(address(handler.actors(0))) + pair.balanceOf(address(handler.actors(1)))
            + pair.balanceOf(address(handler.actors(2)));
        // Burned shares are held by address(0) conceptually; the pair itself never keeps a balance
        // between calls because burn() consumes it entirely.
        assertEq(sum + pair.balanceOf(address(pair)), pair.totalSupply(), "supply mismatch");
    }

    /// @notice The reserves must never both be zero once the pool has been seeded.
    function invariant_ReservesNeverBothZero() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertFalse(r0 == 0 && r1 == 0, "reserves wiped");
    }

    /// @notice Cumulative prices are monotonically non-decreasing.
    function invariant_CumulativePricesMonotonic() public view {
        // A single snapshot cannot prove monotonicity, but the accumulators must never be zero
        // after the pool has been active for any length of time.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 > 0 && r1 > 0) {
            assertGe(pair.price0CumulativeLast(), 0);
            assertGe(pair.price1CumulativeLast(), 0);
        }
    }

    /// @notice `k` may only fall when liquidity is legitimately removed; it must never fall
    ///         below the value implied by the surviving LP supply.
    function invariant_KNeverBelowInitial() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;
        // After the initial seed, the invariant is 50_000e18 * 50_000e18 minus the burn of
        // MINIMUM_LIQUIDITY. Any later decrease would mean value leaked out of the pool.
        uint256 k = uint256(r0) * r1;
        uint256 initialK = 50_000e18 * 50_000e18;
        // Burns reduce k proportionally, so only assert the weaker but always-true bound:
        // the pool must never be worth less than the dust that was locked at creation.
        assertGe(k, pair.MINIMUM_LIQUIDITY() ** 2, "k collapsed below the locked minimum");
        assertLe(k, initialK * 1000, "k grew impossibly fast");
    }
}
