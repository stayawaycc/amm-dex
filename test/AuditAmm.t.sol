// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { AmmFactory } from "../src/AmmFactory.sol";
import { AmmPair } from "../src/AmmPair.sol";
import { AmmRouter } from "../src/AmmRouter.sol";
import { TwapOracle } from "../src/TwapOracle.sol";
import { FlashArbExecutor } from "../src/FlashArbExecutor.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { WETH9 } from "../src/mocks/WETH9.sol";
import { IAmmPair } from "../src/interfaces/IAmmPair.sol";

/// @title FeeOnTransferToken
/// @notice ERC-20 that burns 1% on every transfer. Used to probe whether the AMM's balance-delta
///         accounting survives a token that does not deliver what was sent.
contract FeeOnTransferToken {
    string public name = "Fee Token";
    string public symbol = "FEE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 fee = amount / 100;
        uint256 net = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += net;
        totalSupply -= fee;
        emit Transfer(from, to, net);
    }
}

/// @title AuditAmmTest
/// @notice Adversarial probes for the AMM. Each test asserts a property that must hold; a failure
///         is a real finding, not a test bug.
contract AuditAmmTest is Test {
    AmmFactory internal factory;
    AmmRouter internal router;
    WETH9 internal weth;
    TwapOracle internal oracle;
    FlashArbExecutor internal arb;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");
    address internal keeper = makeAddr("keeper");

    /// @dev The router refunds unused ETH to msg.sender, so a test contract that calls the ETH
    ///      paths must be able to receive it.
    receive() external payable { }

    function setUp() public {
        vm.warp(1_700_000_000);
        factory = new AmmFactory(address(this));
        weth = new WETH9();
        router = new AmmRouter(address(factory), address(weth));
        oracle = new TwapOracle(address(factory));
        arb = new FlashArbExecutor(address(factory), address(this), address(this));

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenC = new MockERC20("C", "C", 18);

        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
        tokenC.mint(alice, 1_000_000e18);
        tokenA.mint(attacker, 1_000_000e18);
        tokenB.mint(attacker, 1_000_000e18);
        tokenC.mint(attacker, 1_000_000e18);

        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(attacker);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();

        // The probes act as a stranger; hand the keeper role to a neutral party so
        // permission changes are observable.
        oracle.setKeeper(keeper);
        tokenA.mint(address(this), 1_000_000e18);
        tokenB.mint(address(this), 1_000_000e18);
        tokenC.mint(address(this), 1_000_000e18);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);

        vm.deal(alice, 100 ether);
        vm.deal(attacker, 100 ether);
        vm.deal(address(this), 1_000 ether);
    }

    // =====================================================================
    // Probe 1: skim underflow
    // =====================================================================

    /// @notice If the pair's real balance is below its cached reserve, `skim` underflows and reverts.
    /// @dev Not a fund-loss bug, but it means `skim` cannot be used as a rescue path in exactly the
    ///      situation (rebasing / fee-on-transfer token) where it would be most needed.
    function test_SkimRevertsWhenBalanceBelowReserve() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 1_000e18);
        tokenB.transfer(address(pair), 1_000e18);
        pair.mint(address(this));

        // Simulate a rebase-down: shrink the pair's real balance below its cached reserve.
        // Post-C-1 the pair itself is the only address allowed to burn its own balance,
        // which is exactly how a real rebasing token would produce the deficit.
        vm.prank(address(pair));
        tokenA.burn(address(pair), 100e18);

        vm.expectRevert();
        pair.skim(alice);

        console2.log("skim() reverts when balance < reserve: confirmed");
    }

    // =====================================================================
    // Probe 2: fee-on-transfer token breaks mint accounting
    // =====================================================================

    /// @notice A fee-on-transfer token must not let an LP mint shares they did not pay for.
    /// @dev The pair derives amounts from balance deltas, so a 1% fee simply reduces the credited
    ///      amount. This asserts the LP cannot end up with more value than they delivered.
    function test_FeeOnTransferTokenDoesNotOverCreditLp() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(address(this), 10_000e18);

        AmmPair pair = AmmPair(factory.createPair(address(feeToken), address(tokenB)));
        feeToken.transfer(address(pair), 1_000e18); // 990 actually arrive
        tokenB.transfer(address(pair), 1_000e18);
        uint256 liquidity = pair.mint(address(this));

        (uint112 r0, uint112 r1,) = pair.getReserves();
        console2.log("reserve0 after fee-token mint:", r0);
        console2.log("reserve1 after fee-token mint:", r1);
        console2.log("liquidity minted:", liquidity);

        // The reserve of the FEE token must reflect what actually arrived (990), not what
        // was sent (1000). Which slot it occupies depends on the sorted token addresses,
        // so resolve it instead of hardcoding r0.
        uint256 feeReserve = address(pair.token0()) == address(feeToken) ? r0 : r1;
        assertLe(feeReserve, 990e18 + 1, "pair credited more than it received");
        assertGt(liquidity, 0);
    }

    // =====================================================================
    // Probe 3: FlashArbExecutor residual balance is stealable
    // =====================================================================

    /// @notice `execute` reports only its own balance delta as profit. Post-fix a tokenA
    ///         balance sitting in the executor beforehand stays there and is NOT paid out
    ///         to `profitRecipient`.
    /// @dev Pre-fix the whole balance was treated as profit, so a stranger's transfer was
    ///      swept to the recipient on the next arb; the balance delta closes that.
    function test_ArbDoesNotSweepPreExistingBalanceAsProfit() public {
        // Three balanced pools.
        vm.startPrank(alice);
        router.addLiquidity(address(tokenA), address(tokenB), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);
        router.addLiquidity(address(tokenB), address(tokenC), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);
        router.addLiquidity(address(tokenA), address(tokenC), 10_000e18, 10_000e18, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        // A stranger accidentally sends tokenA to the executor.
        vm.prank(attacker);
        tokenA.transfer(address(arb), 777e18);

        // Create a dislocation so an arb becomes profitable.
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(2_000e18, 0, _path(address(tokenA), address(tokenC)), alice, block.timestamp);
        vm.stopPrank();

        address pairAB = factory.getPair(address(tokenA), address(tokenB));
        address pairBC = factory.getPair(address(tokenB), address(tokenC));
        address pairCA = factory.getPair(address(tokenA), address(tokenC));

        uint256 recipientBefore = tokenA.balanceOf(address(this));
        uint256 profit = arb.execute(pairAB, pairBC, pairCA, address(tokenB), 500e18);
        uint256 received = tokenA.balanceOf(address(this)) - recipientBefore;

        console2.log("profit reported:", profit);
        console2.log("tokenA actually received by recipient:", received);

        // The reported profit is only the arb's own earnings; the stray 777 stays put.
        assertLt(profit, 777e18, "pre-existing balance must not be swept into the reported profit");
        assertEq(tokenA.balanceOf(address(arb)), 777e18, "stray tokens stay in the executor");
    }

    // =====================================================================
    // Probe 4: TWAP observation is a single slot, overwritable by anyone
    // =====================================================================

    /// @notice Anyone can call `update` and reset the observation, so a consumer that trusts the
    ///         oracle's stored snapshot is at the mercy of whoever last touched it.
    /// @dev The design intends callers to manage their own window, but the shared single-slot
    ///      storage makes concurrent consumers step on each other.
    function test_StrangerCannotOverwriteObservation() public {
        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), 10_000e18);
        tokenB.transfer(address(pair), 10_000e18);
        pair.mint(address(this));

        // The audit contract created this oracle, so it is the keeper; the role was already
        // handed to the neutral `keeper` in setUp, so the update below is the keeper's.
        vm.prank(keeper);
        oracle.update(address(pair));
        (,, uint32 firstTs) = oracle.observations(address(pair));

        vm.warp(block.timestamp + 300);
        pair.sync();

        vm.prank(attacker);
        vm.expectRevert("TwapOracle: FORBIDDEN");
        oracle.update(address(pair));
        (,, uint32 secondTs) = oracle.observations(address(pair));

        assertEq(secondTs, firstTs, "a stranger must not be able to overwrite the observation");
        console2.log("first observation ts :", firstTs);
        console2.log("second observation ts:", secondTs);
    }

    // =====================================================================
    // Probe 5: removeLiquidityETH leaves nothing stuck in the router
    // =====================================================================

    /// @notice The router routes both legs through itself during removeLiquidityETH. Assert that no
    ///         token or ETH remains afterwards.
    function test_RemoveLiquidityEthLeavesRouterClean() public {
        router.addLiquidityETH{ value: 10 ether }(address(tokenA), 10_000e18, 0, 0, address(this), block.timestamp);
        address pair = factory.getPair(address(tokenA), address(weth));
        AmmPair(pair).approve(address(router), type(uint256).max);
        uint256 lp = AmmPair(pair).balanceOf(address(this));
        router.removeLiquidityETH(address(tokenA), lp, 0, 0, address(this), block.timestamp);

        assertEq(tokenA.balanceOf(address(router)), 0, "tokenA stuck in router");
        assertEq(weth.balanceOf(address(router)), 0, "WETH stuck in router");
        assertEq(address(router).balance, 0, "ETH stuck in router");
    }

    // =====================================================================
    // Probe 6: swapExactETHForTokens must consume exactly msg.value
    // =====================================================================

    /// @notice If the router deposits less than msg.value, the remainder is stranded.
    function test_SwapExactEthForTokensConsumesAllValue() public {
        router.addLiquidityETH{ value: 100 ether }(address(tokenA), 100_000e18, 0, 0, address(this), block.timestamp);
        router.swapExactETHForTokens{ value: 1 ether }(
            0, _path(address(weth), address(tokenA)), address(this), block.timestamp
        );

        assertEq(address(router).balance, 0, "ETH stranded in router");
        assertEq(weth.balanceOf(address(router)), 0, "WETH stranded in router");
    }

    // =====================================================================
    // Probe 7: k must never decrease across a swap even with extreme inputs
    // =====================================================================

    function testFuzz_KNeverDecreases(uint96 amountIn, uint96 seed) public {
        uint256 liquidity = bound(uint256(seed), 1e18, 500_000e18);
        uint256 input = bound(uint256(amountIn), 1, liquidity / 2);

        AmmPair pair = AmmPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(pair), liquidity);
        tokenB.transfer(address(pair), liquidity);
        pair.mint(address(this));

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * r1;

        uint256 out = (input * 997 * r1) / (uint256(r0) * 1000 + input * 997);
        vm.assume(out > 0);

        tokenA.transfer(address(pair), input);
        pair.swap(0, out, attacker, new bytes(0));

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGe(uint256(r0After) * r1After, kBefore, "k decreased");
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }
}
