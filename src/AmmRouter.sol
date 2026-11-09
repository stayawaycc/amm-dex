// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IAmmPair } from "./interfaces/IAmmPair.sol";
import { IAmmFactory } from "./interfaces/IAmmFactory.sol";
import { IWETH } from "./interfaces/IWETH.sol";
import { AmmLibrary } from "./libraries/AmmLibrary.sol";

/// @title AmmRouter
/// @notice Stateless entry point for liquidity provision and multi-hop swaps.
/// @dev The router never holds a balance between transactions: every token transfer it
///      initiates is immediately followed by a call that consumes it. ETH is supported through
///      a WETH wrapper so the core pair only ever deals with ERC-20s.
contract AmmRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable WETH;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "AmmRouter: EXPIRED");
        _;
    }

    constructor(address factory_, address weth_) {
        require(factory_ != address(0) && weth_ != address(0), "AmmRouter: ZERO_ADDRESS");
        factory = factory_;
        WETH = weth_;
    }

    // ---------------------------------------------------------------------
    // Receive
    // ---------------------------------------------------------------------

    /// @dev Only WETH may send ETH to the router, during unwrap.
    receive() external payable {
        require(msg.sender == WETH, "AmmRouter: INVALID_SENDER");
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @notice Adds liquidity to a pair, creating it if it does not exist yet.
    /// @dev Liquidity is minted to `to`, never to the router, so no dust is ever stranded.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = AmmLibrary.pairFor(factory, tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IAmmPair(pair).mint(to);
    }

    /// @notice Adds liquidity with ETH on one side.
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        (amountToken, amountETH) = _addLiquidity(
            token, WETH, amountTokenDesired, msg.value, amountTokenMin, amountETHMin
        );
        address pair = AmmLibrary.pairFor(factory, token, WETH);
        IERC20(token).safeTransferFrom(msg.sender, pair, amountToken);
        IWETH(WETH).deposit{ value: amountETH }();
        require(IERC20(WETH).transfer(pair, amountETH), "AmmRouter: WETH_TRANSFER_FAILED");
        liquidity = IAmmPair(pair).mint(to);
        // Refund any ETH that was not needed.
        if (msg.value > amountETH) _safeTransferETH(msg.sender, msg.value - amountETH);
    }

    /// @notice Removes liquidity and returns the underlying tokens to `to`.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        return _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);
    }

    /// @notice Removes liquidity and unwraps the WETH side into ETH.
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = _removeLiquidity(token, WETH, liquidity, amountTokenMin, amountETHMin, address(this));
        IERC20(token).safeTransfer(to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    // ---------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------

    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        amounts = AmmLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "AmmRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, AmmLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Swaps tokens for an exact amount of output tokens.
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        amounts = AmmLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "AmmRouter: EXCESSIVE_INPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, AmmLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Swaps an exact amount of ETH for tokens.
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "AmmRouter: INVALID_PATH");
        amounts = AmmLibrary.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "AmmRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWETH(WETH).deposit{ value: amounts[0] }();
        require(
            IERC20(WETH).transfer(AmmLibrary.pairFor(factory, path[0], path[1]), amounts[0]),
            "AmmRouter: WETH_TRANSFER_FAILED"
        );
        _swap(amounts, path, to);
    }

    /// @notice Swaps tokens for an exact amount of ETH.
    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "AmmRouter: INVALID_PATH");
        amounts = AmmLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "AmmRouter: EXCESSIVE_INPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, AmmLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        _safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /// @notice Swaps an exact amount of tokens for ETH.
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "AmmRouter: INVALID_PATH");
        amounts = AmmLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "AmmRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, AmmLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        _safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /// @notice Swaps an exact amount of ETH for an exact amount of tokens.
    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "AmmRouter: INVALID_PATH");
        amounts = AmmLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, "AmmRouter: EXCESSIVE_INPUT_AMOUNT");
        IWETH(WETH).deposit{ value: amounts[0] }();
        require(
            IERC20(WETH).transfer(AmmLibrary.pairFor(factory, path[0], path[1]), amounts[0]),
            "AmmRouter: WETH_TRANSFER_FAILED"
        );
        _swap(amounts, path, to);
        if (msg.value > amounts[0]) _safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // ---------------------------------------------------------------------
    // Quotes
    // ---------------------------------------------------------------------

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256 amountB) {
        require(amountA > 0, "AmmRouter: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "AmmRouter: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory) {
        return AmmLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory) {
        return AmmLibrary.getAmountsIn(factory, amountOut, path);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Burns LP tokens and enforces the caller's minimum amounts.
    function _removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) internal returns (uint256 amountA, uint256 amountB) {
        address pair = AmmLibrary.pairFor(factory, tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IAmmPair(pair).burn(to);
        (address token0,) = AmmLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, "AmmRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "AmmRouter: INSUFFICIENT_B_AMOUNT");
    }

    /// @dev Computes the optimal amounts to add, then verifies the caller's slippage bounds.
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        if (IAmmFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IAmmFactory(factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = AmmLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "AmmRouter: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                // amountAOptimal <= amountADesired is guaranteed by the branch above.
                require(amountAOptimal >= amountAMin, "AmmRouter: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /// @dev Executes a pre-computed multi-hop swap. Assumes the first hop is already funded.
    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = AmmLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? AmmLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IAmmPair(AmmLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{ value: value }("");
        require(success, "AmmRouter: ETH_TRANSFER_FAILED");
    }
}
