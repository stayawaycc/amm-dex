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
import { IAmmFactory } from "../src/interfaces/IAmmFactory.sol";
import { AmmLibrary } from "../src/libraries/AmmLibrary.sol";

/// @title BaseTest
/// @notice Shared fixture: factory, router, WETH, three 18-decimal tokens and a funded actor.
/// @dev Every test starts from a deterministic state so failures are reproducible from the seed.
abstract contract BaseTest is Test {
    AmmFactory internal factory;
    AmmRouter internal router;
    WETH9 internal weth;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal feeTo = makeAddr("feeTo");

    uint256 internal constant INITIAL_BALANCE = 1_000_000e18;

    function setUp() public virtual {
        factory = new AmmFactory(address(this));
        weth = new WETH9();
        router = new AmmRouter(address(factory), address(weth));

        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        tokenC = new MockERC20("Token C", "TKC", 18);

        address[3] memory tokens = [address(tokenA), address(tokenB), address(tokenC)];
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                MockERC20(tokens[i]).mint(actors[j], INITIAL_BALANCE);
            }
        }

        // The test contract itself acts as an LP in several cases.
        tokenA.mint(address(this), INITIAL_BALANCE);
        tokenB.mint(address(this), INITIAL_BALANCE);
        tokenC.mint(address(this), INITIAL_BALANCE);

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(address(this), 1000 ether);

        // Wrap part of the test contract's ETH so ETH-path tests can seed WETH pairs directly.
        weth.deposit{ value: 200 ether }();

        // The test contract itself is the msg.sender in router tests, so it needs allowances too.
        _approveAll(address(this));

        // Keep timestamps realistic so TWAP windows behave like production.
        vm.warp(1_700_000_000);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _createPair(address a, address b) internal returns (AmmPair pair) {
        pair = AmmPair(factory.createPair(a, b));
    }

    /// @dev Seeds a pair directly, bypassing the router, so unit tests stay independent of it.
    ///      Reuses an existing pair so tests that already created one in `setUp` still work.
    function _seedPair(address a, address b, uint256 amountA, uint256 amountB) internal returns (AmmPair pair) {
        address existing = factory.getPair(a, b);
        pair = existing == address(0) ? _createPair(a, b) : AmmPair(existing);
        MockERC20(a).transfer(address(pair), amountA);
        MockERC20(b).transfer(address(pair), amountB);
        pair.mint(address(this));
    }

    function _approveAll(address owner_) internal {
        address[4] memory tokens = [address(tokenA), address(tokenB), address(tokenC), address(weth)];
        for (uint256 i; i < tokens.length; ++i) {
            vm.prank(owner_);
            MockERC20(tokens[i]).approve(address(router), type(uint256).max);
        }
    }

    /// @dev Invariant helper: the product of reserves must never decrease.
    function _assertKNonDecreasing(AmmPair pair, uint256 kBefore) internal view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGe(uint256(r0) * r1, kBefore, "k decreased");
    }

    function _k(AmmPair pair) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return uint256(r0) * r1;
    }
}
