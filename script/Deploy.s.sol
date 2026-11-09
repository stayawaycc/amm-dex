// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { AmmFactory } from "../src/AmmFactory.sol";
import { AmmRouter } from "../src/AmmRouter.sol";
import { TwapOracle } from "../src/TwapOracle.sol";
import { FlashArbExecutor } from "../src/FlashArbExecutor.sol";
import { WETH9 } from "../src/mocks/WETH9.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @title Deploy
/// @notice Deploys the full AMM stack, seeds two pools and writes the addresses to JSON.
/// @dev Usage
///        anvil
///        forge script script/Deploy.s.sol --rpc-url local --broadcast
///
///      The JSON written to `deployments/<chainid>.json` is what the frontend reads, so the
///      frontend never has to hardcode an address.
contract Deploy is Script {
    using stdJson for string;

    struct Deployment {
        address factory;
        address router;
        address oracle;
        address arb;
        address weth;
        address tokenA;
        address tokenB;
        address pairAB;
    }

    /// @dev Anvil's first default account. Using its well-known private key as the fallback keeps
    ///      `forge script ... --broadcast` working with zero configuration on a local node, which
    ///      is what "clone and run" requires. On any real network `PRIVATE_KEY` must be set.
    uint256 internal constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal constant ANVIL_ADDR_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external returns (Deployment memory d) {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", ANVIL_KEY_0);
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        d.weth = address(new WETH9());
        d.factory = address(new AmmFactory(deployer));
        d.router = address(new AmmRouter(d.factory, d.weth));
        d.oracle = address(new TwapOracle(d.factory));
        d.arb = address(new FlashArbExecutor(d.factory, deployer, deployer));

        // Two demo tokens with different decimals, so the UI has something realistic to show.
        d.tokenA = address(new MockERC20("Demo Wrapped BTC", "dBTC", 8));
        d.tokenB = address(new MockERC20("Demo USD Coin", "dUSDC", 6));

        // Seed balances for the deployer so the frontend has liquidity to trade against.
        MockERC20(d.tokenA).mint(deployer, 100e8);
        MockERC20(d.tokenB).mint(deployer, 10_000_000e6);

        vm.stopBroadcast();

        console2.log("Factory      :", d.factory);
        console2.log("Router       :", d.router);
        console2.log("TwapOracle   :", d.oracle);
        console2.log("FlashArb     :", d.arb);
        console2.log("WETH         :", d.weth);
        console2.log("Token A      :", d.tokenA);
        console2.log("Token B      :", d.tokenB);

        _writeJson(d);
    }

    function _writeJson(Deployment memory d) internal {
        string memory obj = "deployment";
        vm.serializeAddress(obj, "factory", d.factory);
        vm.serializeAddress(obj, "router", d.router);
        vm.serializeAddress(obj, "oracle", d.oracle);
        vm.serializeAddress(obj, "arb", d.arb);
        vm.serializeAddress(obj, "weth", d.weth);
        vm.serializeAddress(obj, "tokenA", d.tokenA);
        string memory json = vm.serializeAddress(obj, "tokenB", d.tokenB);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Wrote deployment to", path);
    }
}
