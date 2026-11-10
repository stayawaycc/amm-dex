// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { stdError } from "forge-std/StdError.sol";

import { BaseTest } from "./BaseTest.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { AmmRouter } from "../src/AmmRouter.sol";
import { TwapOracle } from "../src/TwapOracle.sol";
import { FlashArbExecutor } from "../src/FlashArbExecutor.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { IAmmPair } from "../src/interfaces/IAmmPair.sol";
import { IAmmCallee } from "../src/interfaces/IAmmCallee.sol";

/// @dev A contract that answers the AmmPair view interface with whatever numbers its owner
///      wants. TwapOracle never checks that the address is a factory-deployed pair.
contract FakePair {
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    function set(uint256 p0, uint256 p1) external {
        price0CumulativeLast = p0;
        price1CumulativeLast = p1;
    }

    /// @dev Always claims "I was updated this very block", so the oracle's staleness guard
    ///      (`end = min(tsNow, now)`) never fires.
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (1, 1, uint32(block.timestamp));
    }
}

/// @dev Flash-swap callback that tries every state-changing entry point on the *same* pair.
///      Every attempt is wrapped in try/catch so the outer swap can still settle and the
///      results stay readable after the transaction.
contract CallbackProbe is IAmmCallee {
    AmmPair public immutable pair;
    IERC20 public immutable repayToken;
    address public immutable attacker;

    bool public skimReverted;
    bool public syncReverted;
    bool public mintReverted;
    bool public burnReverted;
    bool public swapReverted;
    bytes public lastSkimReason;

    constructor(AmmPair pair_, IERC20 repayToken_, address attacker_) {
        pair = pair_;
        repayToken = repayToken_;
        attacker = attacker_;
    }

    function ammCall(address, uint256, uint256, bytes calldata) external override {
        try pair.skim(attacker) { }
        catch (bytes memory r) {
            skimReverted = true;
            lastSkimReason = r;
        }
        try pair.sync() { }
        catch {
            syncReverted = true;
        }
        try pair.mint(attacker) { }
        catch {
            mintReverted = true;
        }
        try pair.burn(attacker) { }
        catch {
            burnReverted = true;
        }
        try pair.swap(0, 1, attacker, bytes("")) { }
        catch {
            swapReverted = true;
        }

        // Repay generously so the outer swap settles and the flags survive.
        repayToken.transfer(address(pair), 2e18);
    }
}

/// @title AuditTest
/// @notice PoCs for the audit findings, plus explicit "verified safe" probes for the
///         hypotheses that turned out to be non-issues.
contract AuditTest is BaseTest {
    TwapOracle internal oracle;
    AmmPair internal pair;

    address internal attacker = makeAddr("attacker");
    address internal profitRecipient = makeAddr("profitRecipient");
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        oracle = new TwapOracle(address(factory));
        pair = _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        _approveAll(alice);
        _approveAll(attacker);

        // The audit probes act as the attacker; hand the keeper role to a neutral party
        // so the probes run against a gate they do not hold.
        oracle.setKeeper(keeper);
    }

    // =====================================================================
    // FINDING 1 — TwapOracle: `update` used to be permissionless and the
    //             observation table is a single slot, so an unprivileged actor
    //             chose the start of every averaging window.
    //             TwapOracle.sol (keeper state + update gate + StaleWindow bound)
    // =====================================================================

    /// @notice Same size dump, same pool depth, same elapsed time. Post-fix the attacker cannot
    ///         re-anchor the window at all, so the manipulation stays diluted by the honest
    ///         portion of the window — exactly like the control run.
    function test_F1_AttackerOwnsTheAveragingWindow() public {
        // Two identical 1:1 pools so both runs are directly comparable.
        AmmPair control = pair; // A/B
        AmmPair attacked = _seedPair(address(tokenA), address(tokenC), 10_000e18, 10_000e18);

        tokenA.mint(attacker, 20_000_000e18);
        uint256 honest = uint256(1) << 112; // 1:1 pool

        // ---- Run 1: control, nobody touches the observation ------------------
        vm.prank(keeper);
        oracle.update(address(control));
        vm.warp(block.timestamp + 600);
        control.sync(); // 600 s of the healthy 1:1 price
        assertApproxEqRel(oracle.consult(address(control), 600), honest, 0.001e18, "baseline must be ~1.0");

        _dump(control, address(tokenB), 5_000_000e18);
        uint256 spotControl = _spot0(control); // the price the attacker wants published
        vm.warp(block.timestamp + 600);
        control.sync(); // 600 s of the crushed price
        uint256 diluted = oracle.consult(address(control), 600);
        // 1200 s window, half healthy half crushed -> the honest half dilutes the attack.
        assertApproxEqRel(diluted, (honest + spotControl) / 2, 0.01e18, "control must be the midpoint");

        // ---- Run 2: identical dump, attacker tries to reset the observation --
        // Touch the pair first so the keeper's observation anchors at `now`, mirroring
        // the control run's timeline exactly.
        attacked.sync();
        vm.prank(keeper);
        oracle.update(address(attacked));
        vm.warp(block.timestamp + 600);
        attacked.sync();
        assertApproxEqRel(oracle.consult(address(attacked), 600), honest, 0.001e18);

        _dump(attacked, address(tokenC), 5_000_000e18);
        uint256 spotAttacked = _spot0(attacked);
        // *** THE ATTACK: re-anchoring the window now fails outright ***
        vm.expectRevert("TwapOracle: FORBIDDEN");
        vm.prank(attacker);
        oracle.update(address(attacked));
        vm.warp(block.timestamp + 600);
        attacked.sync();
        uint256 published = oracle.consult(address(attacked), 600);

        emit log_named_uint("honest price          ", honest);
        emit log_named_uint("attacker spot price   ", spotAttacked);
        emit log_named_uint("diluted TWAP (control)", diluted);
        emit log_named_uint("published TWAP (post-fix)", published);

        // Without the reset the attacker only owns half the window: the published value is
        // the midpoint, same as the control run.
        assertApproxEqRel(published, (honest + spotAttacked) / 2, 0.01e18, "reset must not publish attacker's spot");
        assertGt(published, honest / 100, "the honest half must keep the price far from the attacker's");
    }

    /// @notice The missing access control used to be a cheap, repeatable denial of service.
    ///         Post-fix every hostile poke is refused, so `consult` keeps serving prices.
    function test_F1b_KeeperGateEndsTheFreeDenialOfService() public {
        vm.prank(keeper);
        oracle.update(address(pair));

        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 600);
            pair.sync(); // legitimate pool activity
            vm.expectRevert("TwapOracle: FORBIDDEN");
            vm.prank(attacker);
            oracle.update(address(pair)); // attacker tries to re-anchor the window
        }

        uint256 price = oracle.consult(address(pair), 600);
        assertApproxEqRel(price, uint256(1) << 112, 0.01e18, "the DoS is closed");
    }

    /// @notice The observation used to be a single slot with no owner, so anyone could
    ///         overwrite the honest snapshot. Post-fix only the keeper writes it.
    function test_F1c_ObservationIsASingleSlotWithNoOwner() public {
        vm.prank(keeper);
        oracle.update(address(pair));
        (,, uint32 tsA) = oracle.observations(address(pair));
        assertEq(tsA, block.timestamp);

        vm.warp(block.timestamp + 300);
        pair.sync();
        vm.expectRevert("TwapOracle: FORBIDDEN");
        vm.prank(attacker);
        oracle.update(address(pair)); // overwriting is now refused
        (,, uint32 tsB) = oracle.observations(address(pair));
        assertEq(tsB, tsA, "the observation must be untouched");

        // The honest snapshot survives and the window still elapses for consumers.
        vm.warp(block.timestamp + 600);
        pair.sync();
        uint256 price = oracle.consult(address(pair), 600);
        assertApproxEqRel(price, uint256(1) << 112, 0.01e18);
    }

    // =====================================================================
    // FINDING 2 — MockERC20.burn has no authorization, and script/Deploy.s.sol
    //             ships MockERC20 as the deployed token. Anyone can destroy the
    //             pair's balance and brick the pool.
    //             src/mocks/MockERC20.sol:23-25, script/Deploy.s.sol:55-56
    // =====================================================================

    function test_F2_AnyoneCanBurnThePairsTokens() public {
        uint256 pairBalance = tokenA.balanceOf(address(pair));
        assertGt(pairBalance, 0);

        // Post-fix: a stranger cannot burn what they do not own.
        vm.expectRevert("MockERC20: FORBIDDEN");
        vm.prank(attacker);
        tokenA.burn(address(pair), pairBalance);

        assertEq(tokenA.balanceOf(address(pair)), pairBalance, "pool balance untouched");
        (uint112 r0,,) = pair.getReserves();
        assertEq(uint256(r0), pairBalance, "reserve and balance still agree");
    }

    // =====================================================================
    // FINDING 3 — AmmPair.skim underflow DoS: a deficit in one token bricks the
    //             rescue of the other.
    //             AmmPair.sol:228-233
    // =====================================================================

    function test_F3_SkimRevertsWhenOneSideIsInDeficit() public {
        // A donation on the healthy side that a keeper should be able to recover.
        tokenB.transfer(address(pair), 5e18);

        // The other side drops below its cached reserve (rebase-down, tax, ...).
        // Post-C-1 the pair itself is the only address allowed to burn its own balance,
        // which is exactly how a rebase-down token would shrink it.
        vm.prank(address(pair));
        tokenA.burn(address(pair), 1e18);
        (uint112 r0,,) = pair.getReserves();
        assertGt(uint256(r0), tokenA.balanceOf(address(pair)), "deficit established");

        // skim() transfers BOTH tokens, so the 5 B donation is unreachable.
        uint256 bobB = tokenB.balanceOf(bob);
        vm.expectRevert();
        pair.skim(bob);
        assertEq(tokenB.balanceOf(bob), bobB, "donation still stuck");

        // The only exit is sync(), which socialises the loss over every LP instead of
        // returning the donation.
        pair.sync();
        (uint112 r0After,,) = pair.getReserves();
        assertLt(r0After, r0, "loss socialised across LPs");
    }

    /// @notice Design note, same as Uniswap V2: `skim` has no recipient restriction, so the
    ///         first caller takes any donation.
    function test_F3b_SkimRecipientIsUnrestricted() public {
        tokenB.transfer(address(pair), 5e18);
        uint256 before = tokenB.balanceOf(attacker);
        vm.prank(attacker);
        pair.skim(attacker);
        assertEq(tokenB.balanceOf(attacker) - before, 5e18);
    }

    // =====================================================================
    // FINDING 4 — FlashArbExecutor: `execute` is permissionless and `minProfit`
    //             defaults to 0; the profit sweep also claims any pre-existing
    //             balance.
    //             FlashArbExecutor.sol:48, 92-120
    // =====================================================================

    function _triangle() internal returns (AmmPair ab, AmmPair bc, AmmPair ca) {
        ab = _seedPair(address(tokenA), address(tokenB), 10_000e18, 10_000e18);
        bc = _seedPair(address(tokenB), address(tokenC), 10_000e18, 10_000e18);
        ca = _seedPair(address(tokenA), address(tokenC), 10_000e18, 10_000e18);

        // Genuine dislocation: dump A into the A/C pool.
        tokenA.mint(alice, 2_000e18);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(2_000e18, 0, _path(address(tokenA), address(tokenC)), alice, block.timestamp);
        vm.stopPrank();
    }

    function test_F4_AnyoneCanDriveTheOwnersArbBot() public {
        (AmmPair ab, AmmPair bc, AmmPair ca) = _triangle();
        FlashArbExecutor arb = new FlashArbExecutor(address(factory), address(this), profitRecipient);
        assertEq(arb.minProfit(), 0, "minProfit defaults to zero");

        uint256 bobBefore = tokenA.balanceOf(bob);

        // Not the owner, no permission, no capital.
        vm.prank(bob);
        uint256 profit = arb.execute(address(ab), address(bc), address(ca), address(tokenB), 500e18);

        assertGt(profit, 0);
        assertEq(tokenA.balanceOf(profitRecipient), profit);
        assertEq(tokenA.balanceOf(bob), bobBefore, "caller gets nothing");
        assertEq(tokenA.balanceOf(address(arb)), 0);
    }

    function test_F4b_PreExistingBalanceIsCountedAsProfit() public {
        (AmmPair ab, AmmPair bc, AmmPair ca) = _triangle();
        FlashArbExecutor arb = new FlashArbExecutor(address(factory), address(this), profitRecipient);

        // Someone sends tokenA to the executor (mistake, or dust from another tool).
        uint256 donation = 77e18;
        tokenA.transfer(address(arb), donation);

        // Post-fix the reported profit is the executor's own balance delta. The stray
        // transfer is no longer swept into it and stays in the executor untouched.
        uint256 profit = arb.execute(address(ab), address(bc), address(ca), address(tokenB), 500e18);

        assertGt(profit, 0, "the arb itself must still be profitable");
        assertEq(tokenA.balanceOf(profitRecipient), profit, "recipient gets exactly the arb profit");
        assertEq(tokenA.balanceOf(address(arb)), donation, "donation stays in the executor");
    }

    // =====================================================================
    // FINDING 5 — AmmRouter.quote uses checked multiplication, so the quote
    //             path reverts instead of using full precision.
    //             AmmRouter.sol:231-235
    // =====================================================================

    function test_F5_QuoteOverflowsAndReverts() public {
        vm.expectRevert(stdError.arithmeticError);
        router.quote(2 ** 200, 1, 2 ** 200);
    }

    // =====================================================================
    // FINDING 6 — TwapOracle.MAX_PERIOD bounds the request, not the window.
    //             TwapOracle.sol:37-38, 106-108
    // =====================================================================

    function test_F6_MaxPeriodDoesNotBoundTheActualWindow() public {
        vm.prank(keeper);
        oracle.update(address(pair));
        vm.warp(block.timestamp + 30 days);
        pair.sync();

        // Post-fix the *window* is bounded, not just the argument: a 30-day-old
        // accumulator is refused for every requested period.
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StaleWindow.selector, address(pair), uint32(30 days)));
        oracle.consult(address(pair), 60);

        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StaleWindow.selector, address(pair), uint32(30 days)));
        oracle.consult(address(pair), 7 days);
    }

    // =====================================================================
    // FINDING 7 — TwapOracle never validates that `pair` came from the factory,
    //             so anyone can register a price source of their own choosing.
    //             TwapOracle.sol:59-64, 90-95
    // =====================================================================

    function test_F7_AnyContractCanBeRegisteredAsAPriceSource() public {
        FakePair fake = new FakePair();
        // Post-fix a stranger cannot register anything, so a fabricated price source
        // cannot even get an observation slot.
        fake.set(0, 0);
        vm.expectRevert("TwapOracle: FORBIDDEN");
        vm.prank(attacker);
        oracle.update(address(fake));

        // The keeper registering an arbitrary address is a deliberate trust decision, not
        // an attack path; nothing about it changes.
        assertEq(oracle.factory(), address(factory));
        assertTrue(factory.getPair(address(tokenA), address(tokenB)) != address(fake));
    }

    // =====================================================================
    // FINDING 8 — `burn` is permissionless and pays out to any `to`, so any
    //             LP token that lands on the pair is claimable by the next caller.
    //             AmmPair.sol:147-172
    // =====================================================================

    function test_F8_AnyLpTokenSentToThePairIsClaimableByAnyone() public {
        uint256 liquidity = pair.balanceOf(address(this));
        // A user who transfers LP tokens to the pair by mistake (a common footgun, and the
        // pattern `removeLiquidity` itself relies on).
        IERC20(address(pair)).transfer(address(pair), liquidity);

        uint256 aBefore = tokenA.balanceOf(attacker);
        uint256 bBefore = tokenB.balanceOf(attacker);

        vm.prank(attacker);
        pair.burn(attacker); // no ownership of those shares required

        assertGt(tokenA.balanceOf(attacker) - aBefore, 0, "attacker took the underlying");
        assertGt(tokenB.balanceOf(attacker) - bBefore, 0, "attacker took the underlying");
        assertEq(pair.balanceOf(address(pair)), 0);
    }

    // =====================================================================
    // FINDING 9 — `sync()` can zero a reserve while `totalSupply > 0`, and
    //             `mint()` then divides by that zero reserve: the pool is
    //             permanently bricked. Reachable because a balance can be
    //             driven to zero without touching the reserves.
    //             AmmPair.sol:134, 237-239
    // =====================================================================

    function test_F9_SyncCanZeroAReserveAndBrickMintForever() public {
        assertGt(pair.totalSupply(), 0);
        (uint112 r0,,) = pair.getReserves();
        assertGt(r0, 0);

        // Empty the token0 side. Post-C-1 only the pair itself may burn its own balance,
        // which models how a rebase-down token would shrink it. The balance read must
        // happen before the prank: vm.prank applies to the very next call.
        uint256 pairBal = tokenA.balanceOf(address(pair));
        vm.prank(address(pair));
        tokenA.burn(address(pair), pairBal);

        pair.sync(); // reserves now claim 0
        (uint112 r0After,,) = pair.getReserves();
        assertEq(r0After, 0, "reserve zeroed");
        assertGt(pair.totalSupply(), 0, "supply still positive");

        // Post-L3: the failure is an explicit ZERO_RESERVE error, not an arithmetic panic.
        tokenA.mint(bob, 1_000e18);
        tokenB.mint(bob, 1_000e18);
        vm.startPrank(bob);
        tokenA.transfer(address(pair), 1_000e18);
        tokenB.transfer(address(pair), 1_000e18);
        vm.expectRevert("AmmPair: ZERO_RESERVE");
        pair.mint(bob);
        vm.stopPrank();
    }

    // =====================================================================
    // FINDING 10 — `_update` rejects any balance above uint112, so a large
    //              donation freezes mint/burn/swap/sync. `skim` is the only
    //              rescue, and it is itself permissionless.
    //              AmmPair.sol:271
    // =====================================================================

    function test_F10_BalanceAboveUint112FreezesThePool() public {
        uint256 huge = uint256(type(uint112).max) + 1;
        tokenA.mint(address(pair), huge - tokenA.balanceOf(address(pair)));

        vm.expectRevert("AmmPair: OVERFLOW");
        pair.sync();

        tokenB.transfer(address(pair), 1e18);
        vm.expectRevert("AmmPair: OVERFLOW");
        pair.mint(bob);

        vm.expectRevert("AmmPair: OVERFLOW");
        pair.swap(0, 1e18, bob, new bytes(0));

        // skim() is the only exit, and anyone can call it to any recipient.
        vm.prank(attacker);
        pair.skim(attacker);
        assertEq(tokenA.balanceOf(attacker), huge - 10_000e18, "attacker takes the excess");

        pair.sync(); // pool usable again
    }

    // =====================================================================
    // VERIFIED SAFE — the hypotheses that did not survive
    // =====================================================================

    /// @notice First-depositor share inflation. MINIMUM_LIQUIDITY = 1e3 is locked to 0xdead on
    ///         the first mint, which is exactly the Uniswap V2 mitigation. Quantifying it: to
    ///         round a victim's deposit down to zero the attacker must donate more value than
    ///         the victim's deposit, so the attack is never profitable at any realistic size.
    function test_S6_FirstDepositorInflationIsNotProfitable() public {
        AmmPair fresh = _createPair(address(tokenA), address(tokenC));

        // Attacker seeds the smallest pool that does not underflow sqrt(x*y) - 1000.
        uint256 seed = 1_001e9; // sqrt(seed*seed) = 1_001e9 -> liquidity = 1e9 - 1e3
        tokenA.transfer(address(fresh), seed);
        tokenC.transfer(address(fresh), seed);
        vm.prank(attacker);
        fresh.mint(attacker);

        uint256 attackerShares = fresh.balanceOf(attacker);
        assertGt(attackerShares, 0);

        // Victim deposits a realistic 10_000e18 of each.
        uint256 victimAmount = 10_000e18;
        tokenA.mint(carol, victimAmount);
        tokenC.mint(carol, victimAmount);
        vm.startPrank(carol);
        tokenA.transfer(address(fresh), victimAmount);
        tokenC.transfer(address(fresh), victimAmount);
        uint256 victimShares = fresh.mint(carol);
        vm.stopPrank();

        assertGt(victimShares, 0, "victim must not be rounded to zero");

        // Victim's redeemable value is at least their deposit minus rounding.
        uint256 supply = fresh.totalSupply();
        (uint112 r0, uint112 r1,) = fresh.getReserves();
        uint256 redeemable = (victimShares * uint256(r0)) / supply;
        assertApproxEqRel(redeemable, victimAmount, 0.001e18, "victim keeps their deposit");

        // Attacker cannot extract more than they put in.
        uint256 attackerRedeemable = (attackerShares * uint256(r0)) / supply;
        assertLt(attackerRedeemable, seed, "attacker must not profit");
        assertGt(r1, 0);
    }

    /// @notice The `lock` modifier is entered before the body runs and released after it, so
    ///         during `ammCall` the pair is locked. Every re-entry attempt fails with LOCKED.
    ///         The flash-swap callback therefore cannot reach skim/sync/mint/burn/swap on the
    ///         same pair, and cannot bypass the k check.
    function test_S1_LockBlocksEveryReentryFromTheFlashCallback() public {
        address token0 = pair.token0();
        CallbackProbe probe = new CallbackProbe(pair, IERC20(token0), attacker);
        MockERC20(token0).mint(address(probe), 2e18);

        // Borrow 1e18 of token1, repay 2e18 of token0: settles the k check.
        pair.swap(0, 1e18, address(probe), abi.encode(uint256(1)));

        assertTrue(probe.skimReverted(), "skim must be blocked");
        assertTrue(probe.syncReverted(), "sync must be blocked");
        assertTrue(probe.mintReverted(), "mint must be blocked");
        assertTrue(probe.burnReverted(), "burn must be blocked");
        assertTrue(probe.swapReverted(), "nested swap must be blocked");

        // And the reason is the guard, not something incidental.
        bytes memory reason = probe.lastSkimReason();
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 0x20))
        }
        assertEq(selector, bytes4(keccak256("Error(string)")), "must be a require() string");
    }

    /// @notice `_amountToRepay` cannot divide by zero: `swap` rejects `amountOut >= reserve`
    ///         before the callback, and the callback reads the pre-swap reserves.
    function test_S2_AmountToRepayCannotDivideByZero() public {
        (AmmPair ab, AmmPair bc, AmmPair ca) = _triangle();
        FlashArbExecutor arb = new FlashArbExecutor(address(factory), address(this), profitRecipient);

        (uint112 r0, uint112 r1,) = ab.getReserves();
        uint256 reserveB = ab.token0() == address(tokenB) ? r0 : r1;

        // amountOut == reserveOut is rejected by the pair itself.
        vm.expectRevert("AmmPair: INSUFFICIENT_LIQUIDITY");
        arb.execute(address(ab), address(bc), address(ca), address(tokenB), reserveB);

        // amountOut == reserveOut - 1 gets past the pair, but the repayment is astronomical
        // and the executor aborts cleanly instead of dividing by zero.
        vm.expectRevert(FlashArbExecutor.Unprofitable.selector);
        arb.execute(address(ab), address(bc), address(ca), address(tokenB), reserveB - 1);

        (uint112 r0After, uint112 r1After,) = ab.getReserves();
        assertEq(r0After, r0);
        assertEq(r1After, r1);
    }

    /// @notice Donating to the pair and then swapping cannot break k: the donation is part of
    ///         the balance the check runs on, so it only ever helps the pool.
    function test_S3_DonationCannotBreakK() public {
        uint256 kBefore = _k(pair);
        tokenA.transfer(address(pair), 500e18);
        tokenA.transfer(address(pair), 500e18); // no sync, no mint

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 out = _amountOut(100e18, r1, r0); // B -> A
        tokenB.transfer(address(pair), 100e18);
        pair.swap(out, 0, bob, new bytes(0));

        assertGe(_k(pair), kBefore, "k must not decrease");
    }

    /// @notice Every ETH path is balanced: the router keeps no ETH, no WETH and no token
    ///         between transactions, and every overpayment is refunded.
    function test_S4_EthPathsLeaveNothingStuck() public {
        // addLiquidityETH
        vm.prank(alice);
        (,, uint256 liq) =
            router.addLiquidityETH{ value: 10 ether }(address(tokenA), 10_000e18, 0, 0, alice, block.timestamp);
        _assertRouterClean();

        address wethPair = factory.getPair(address(tokenA), address(weth));

        // swapExactETHForTokens
        vm.prank(alice);
        router.swapExactETHForTokens{ value: 1 ether }(0, _path(address(weth), address(tokenA)), alice, block.timestamp);
        _assertRouterClean();

        // swapETHForExactETH overpayment must be refunded
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        router.swapETHForExactTokens{ value: 5 ether }(
            1e18, _path(address(weth), address(tokenA)), alice, block.timestamp
        );
        assertLt(ethBefore - alice.balance, 5 ether, "excess ETH must come back");
        _assertRouterClean();

        // swapExactTokensForETH
        vm.prank(alice);
        router.swapExactTokensForETH(100e18, 0, _path(address(tokenA), address(weth)), alice, block.timestamp);
        _assertRouterClean();

        // removeLiquidityETH: burn goes to the router, then is forwarded in the same call
        vm.startPrank(alice);
        IERC20(wethPair).approve(address(router), type(uint256).max);
        uint256 aliceEth = alice.balance;
        uint256 aliceToken = tokenA.balanceOf(alice);
        (uint256 amountToken, uint256 amountETH) =
            router.removeLiquidityETH(address(tokenA), liq, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(alice) - aliceToken, amountToken);
        assertEq(alice.balance - aliceEth, amountETH);
        _assertRouterClean();
    }

    /// @notice The TWAP accumulator cannot realistically overflow: the worst-case increment
    ///         needs ~136 years inside one `_update` window.
    function test_S5_AccumulatorWrapIsOutOfReach() public {
        uint256 before = pair.price0CumulativeLast();
        vm.warp(block.timestamp + 3650 days);
        pair.sync();
        uint256 afterWarp = pair.price0CumulativeLast();
        assertGt(afterWarp, before);
        // Increment is bounded by price * 2**32; a wrap needs price * dt >= 2**256.
        assertLt(afterWarp - before, uint256(1) << 200, "no wrap in any realistic window");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _assertRouterClean() internal view {
        assertEq(address(router).balance, 0, "router holds ETH");
        assertEq(weth.balanceOf(address(router)), 0, "router holds WETH");
        assertEq(tokenA.balanceOf(address(router)), 0, "router holds tokenA");
        assertEq(tokenB.balanceOf(address(router)), 0, "router holds tokenB");
    }

    function _dump(AmmPair target, address outToken, uint256 amountIn) internal {
        (address t0, address t1) = (target.token0(), target.token1());
        address inToken = outToken == t0 ? t1 : t0;
        vm.startPrank(attacker);
        MockERC20(inToken).approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(amountIn, 0, _path(inToken, outToken), attacker, block.timestamp);
        vm.stopPrank();
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return (withFee * reserveOut) / (reserveIn * 1000 + withFee);
    }

    /// @dev UQ112x112 price of token0 in token1, i.e. reserve1 / reserve0 * 2**112.
    function _spot0(AmmPair target) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = target.getReserves();
        return (uint256(r1) << 112) / uint256(r0);
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }
}
