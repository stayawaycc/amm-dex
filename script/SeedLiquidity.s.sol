// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { AmmFactory } from "../src/AmmFactory.sol";
import { AmmRouter } from "../src/AmmRouter.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @title SeedLiquidity
/// @notice Adds demo liquidity to the pools created by `Deploy`, so the frontend has depth.
/// @dev Run after Deploy:
///        forge script script/SeedLiquidity.s.sol --rpc-url local --broadcast
contract SeedLiquidity is Script {
    using stdJson for string;

    /// @dev Anvil account #0. Same rationale as in `Deploy`.
    uint256 internal constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal constant ANVIL_ADDR_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address payable router = payable(json.readAddress(".router"));
        address tokenA = json.readAddress(".tokenA");
        address tokenB = json.readAddress(".tokenB");

        uint256 deployerKey = vm.envOr("PRIVATE_KEY", ANVIL_KEY_0);
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockERC20(tokenA).approve(router, type(uint256).max);
        MockERC20(tokenB).approve(router, type(uint256).max);

        // 1 dBTC (8 decimals) paired with 60,000 dUSDC (6 decimals), i.e. a 60k price.
        (uint256 amountA, uint256 amountB, uint256 liquidity) = AmmRouter(router)
            .addLiquidity(tokenA, tokenB, 50e8, 3_000_000e6, 0, 0, deployer, block.timestamp + 365 days);

        vm.stopBroadcast();

        console2.log("Seeded tokenA :", amountA);
        console2.log("Seeded tokenB :", amountB);
        console2.log("LP minted     :", liquidity);
    }
}
