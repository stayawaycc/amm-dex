// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IAmmPair } from "./interfaces/IAmmPair.sol";
import { IAmmFactory } from "./interfaces/IAmmFactory.sol";
import { IAmmCallee } from "./interfaces/IAmmCallee.sol";
import { AmmLibrary } from "./libraries/AmmLibrary.sol";

/// @title FlashArbExecutor
/// @notice Capital-free triangular arbitrage inside a single AmmFactory.
/// @dev Why triangular rather than two-pool
///      A factory keys pools by the unordered token pair, so `A/B` can only ever have one pool.
///      Two-pool arbitrage therefore requires a second venue. The structure that *is* available
///      inside one factory is a triangle: `A/B`, `B/C`, `A/C`. When the three implied prices
///      disagree, borrowing one leg and cycling through the other two is profitable, and the
///      loan is repaid out of the proceeds within the same transaction.
///
///      Flow
///        1. `execute` asks pair AB for `amountBorrow` of token B via a flash swap. The pair
///           sends the tokens first and calls `ammCall` before checking its invariant.
///        2. Inside `ammCall` the executor sells B -> C on pair BC, then C -> A on pair CA.
///        3. It repays pair AB in token A, leaving the pool with a non-decreasing invariant.
///        4. Whatever token A remains is profit, paid to `profitRecipient`.
///
///      Safety properties enforced here
///        - `ammCall` only accepts calls from the pair that `execute` is currently using, so an
///          attacker cannot invoke the callback directly to drain the executor.
///        - Only one flash swap may be in flight (reentrancy guard).
///        - Every pair involved must be registered in the factory, so a malicious look-alike
///          contract cannot be substituted.
///        - The repayment is computed from the pool's own curve, rounded up, so the lender is
///          always made whole before profit is taken.
contract FlashArbExecutor is IAmmCallee, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable factory;

    /// @notice The pair currently lending tokens for an in-flight flash swap.
    address public activePair;
    /// @notice The token borrowed from `activePair`.
    address public borrowedToken;
    /// @notice Minimum profit required, denominated in the profit token, to settle.
    uint256 public minProfit;
    /// @notice Recipient of the profit.
    address public profitRecipient;

    event ArbExecuted(
        address indexed pairBorrow, uint256 profit, address indexed profitToken, address indexed recipient
    );

    error UnauthorizedPair(address caller);
    error NotActivePair(address caller);
    error InvalidTriangle();
    error InsufficientProfit(uint256 realised, uint256 required);
    error Unprofitable();

    constructor(address factory_, address owner_, address profitRecipient_) Ownable(owner_) {
        require(factory_ != address(0) && profitRecipient_ != address(0), "FlashArb: ZERO_ADDRESS");
        factory = factory_;
        profitRecipient = profitRecipient_;
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setMinProfit(uint256 minProfit_) external onlyOwner {
        minProfit = minProfit_;
    }

    function setProfitRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "FlashArb: ZERO_ADDRESS");
        profitRecipient = recipient;
    }

    // ---------------------------------------------------------------------
    // Entry point
    // ---------------------------------------------------------------------

    /// @notice Borrows `tokenB` from `pairAB`, cycles it through `pairBC` and `pairCA`, repays
    ///         `pairAB` and forwards the remaining `tokenA` to `profitRecipient`.
    /// @param pairAB The lending pool. Its two tokens must be `tokenA` (repay) and `tokenB` (borrow).
    /// @param pairBC The pool used to convert `tokenB` into `tokenC`.
    /// @param pairCA The pool used to convert `tokenC` back into `tokenA`.
    /// @param tokenB The token to borrow. Must be one of `pairAB`'s tokens.
    /// @param amountBorrow The amount of `tokenB` to borrow.
    function execute(address pairAB, address pairBC, address pairCA, address tokenB, uint256 amountBorrow)
        external
        nonReentrant
        returns (uint256 profit)
    {
        address tokenA = _otherToken(pairAB, tokenB);
        if (!_isRegistered(pairAB) || !_isRegistered(pairBC) || !_isRegistered(pairCA)) {
            revert UnauthorizedPair(pairAB);
        }

        activePair = pairAB;
        borrowedToken = tokenB;

        bool borrowToken0 = IAmmPair(pairAB).token0() == tokenB;
        bytes memory data = abi.encode(pairBC, pairCA, tokenA);

        // Baseline before the flash swap: anything already sitting here belongs to whoever sent
        // it, not to the arb. Counting the whole balance as profit paid stray transfers out to
        // `profitRecipient`; see test/SecurityFixes.t.sol.
        uint256 balanceBefore = IERC20(tokenA).balanceOf(address(this));

        // Take the borrowed token out of the pool: if it is token0, amount0Out carries the loan.
        IAmmPair(pairAB).swap(borrowToken0 ? amountBorrow : 0, borrowToken0 ? 0 : amountBorrow, address(this), data);

        activePair = address(0);
        borrowedToken = address(0);

        profit = IERC20(tokenA).balanceOf(address(this)) - balanceBefore;
        if (profit == 0) revert Unprofitable();
        if (profit < minProfit) revert InsufficientProfit(profit, minProfit);

        IERC20(tokenA).safeTransfer(profitRecipient, profit);
        emit ArbExecuted(pairAB, profit, tokenA, profitRecipient);
    }

    // ---------------------------------------------------------------------
    // Flash swap callback
    // ---------------------------------------------------------------------

    /// @inheritdoc IAmmCallee
    function ammCall(address, uint256 amount0Out, uint256 amount1Out, bytes calldata data) external override {
        if (msg.sender != activePair) revert NotActivePair(msg.sender);

        (address pairBC, address pairCA, address tokenA) = abi.decode(data, (address, address, address));
        address tokenB = borrowedToken;
        uint256 borrowed = amount0Out > 0 ? amount0Out : amount1Out;

        // Leg 1: tokenB -> tokenC on pairBC.
        address tokenC = _otherToken(pairBC, tokenB);
        uint256 amountC = _swapExactIn(pairBC, tokenB, borrowed);

        // Leg 2: tokenC -> tokenA on pairCA. The triangle must actually close.
        if (_otherToken(pairCA, tokenC) != tokenA) revert InvalidTriangle();
        uint256 amountA = _swapExactIn(pairCA, tokenC, amountC);

        // Repay the lender in tokenA, rounded up so the pool's invariant cannot decrease.
        uint256 owed = _amountToRepay(msg.sender, borrowed, tokenB);
        if (amountA < owed) revert Unprofitable();
        IERC20(tokenA).safeTransfer(msg.sender, owed);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _isRegistered(address pair) internal view returns (bool) {
        return IAmmFactory(factory).getPair(IAmmPair(pair).token0(), IAmmPair(pair).token1()) == pair;
    }

    /// @dev Returns the token of `pair` that is not `token`.
    function _otherToken(address pair, address token) internal view returns (address other) {
        address t0 = IAmmPair(pair).token0();
        address t1 = IAmmPair(pair).token1();
        require(token == t0 || token == t1, "FlashArb: UNKNOWN_TOKEN");
        other = token == t0 ? t1 : t0;
    }

    /// @dev Executes one exact-input hop: pays `amountIn` of `tokenIn` into `pair` and receives
    ///      the corresponding output. The input must be transferred before `swap` is called,
    ///      because the pair derives the input amount from its balance delta.
    function _swapExactIn(address pair, address tokenIn, uint256 amountIn) internal returns (uint256 amountOut) {
        (uint256 reserveIn, uint256 reserveOut) = _reservesByInput(pair, tokenIn);
        amountOut = AmmLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut == 0) revert Unprofitable();

        IERC20(tokenIn).safeTransfer(pair, amountIn);

        bool inIsToken0 = IAmmPair(pair).token0() == tokenIn;
        IAmmPair(pair).swap(inIsToken0 ? 0 : amountOut, inIsToken0 ? amountOut : 0, address(this), new bytes(0));
    }

    /// @dev Reserves ordered so that the first value corresponds to `tokenIn`.
    function _reservesByInput(address pair, address tokenIn)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut)
    {
        (uint112 r0, uint112 r1,) = IAmmPair(pair).getReserves();
        bool inIsToken0 = IAmmPair(pair).token0() == tokenIn;
        (reserveIn, reserveOut) = inIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev Minimum amount of `tokenOut` that must be returned to keep the lender's fee-adjusted
    ///      invariant non-decreasing after taking `amountOut` of `tokenOut` out.
    ///
    ///      The pair accepts a repayment `in` when
    ///          (rIn + in * 0.997) * (rOut - out) >= rIn * rOut
    ///      Solving for `in`:
    ///          in >= out * rIn * 1000 / ((rOut - out) * 997)
    ///      and the result is rounded up by 1 wei so integer truncation can never leave the pool
    ///      one wei short.
    function _amountToRepay(address pair, uint256 amountOut, address tokenOut) internal view returns (uint256) {
        (uint256 reserveOut, uint256 reserveIn) = _reservesByInput(pair, tokenOut);
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        return numerator / denominator + 1;
    }
}
