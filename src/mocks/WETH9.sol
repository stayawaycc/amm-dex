// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title WETH9
/// @notice Minimal wrapped-ether implementation used for local development and tests.
/// @dev The real WETH9 on mainnet has the same behaviour. Kept in-tree so the repo has no
///      external dependency for local deployment.
contract WETH9 is ERC20 {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20("Wrapped Ether", "WETH") { }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{ value: wad }("");
        require(ok, "WETH9: ETH_TRANSFER_FAILED");
        emit Withdrawal(msg.sender, wad);
    }
}
