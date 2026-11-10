// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAmmPair } from "./interfaces/IAmmPair.sol";
import { IAmmFactory } from "./interfaces/IAmmFactory.sol";
import { IAmmCallee } from "./interfaces/IAmmCallee.sol";
import { UQ112x112 } from "./libraries/UQ112x112.sol";
import { Math } from "./libraries/Math.sol";

/// @title AmmPair
/// @notice A constant-product (x * y = k) liquidity pool for exactly two ERC-20 tokens.
/// @dev Design notes
///      - Reserves are cached in storage as `uint112` and only trusted after a `Sync`, exactly
///        like Uniswap V2. This keeps the swap path at two SLOADs instead of four.
///      - `price{0,1}CumulativeLast` accumulates the time-weighted price with a 32-bit overflow
///        wraparound, which is safe as long as `update()` is called at least once every
///        2**32 seconds (~136 years). Callers that need a bounded window should poke the pair
///        at least once per window.
///      - The 0.30% fee is charged by keeping 3/1000 of the input inside the pool. The k
///        invariant is therefore checked on fee-adjusted balances.
///      - Flash swaps are supported through the `data` parameter: a caller may take output
///        before paying, as long as the post-swap invariant holds.
contract AmmPair is IAmmPair, ERC20 {
    using SafeERC20 for IERC20;
    using UQ112x112 for uint224;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Minimum liquidity permanently locked on the first mint.
    /// @dev Prevents the total-supply == 0 state, which would allow donation-based
    ///      share-price manipulation on a brand new pool.
    uint256 public constant MINIMUM_LIQUIDITY = 1e3;

    /// @notice Fee numerator. 3/1000 of the input amount stays in the pool.
    uint256 public constant FEE_NUMERATOR = 3;
    uint256 public constant FEE_DENOMINATOR = 1000;

    // ---------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------

    address public immutable override factory;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public override token0;
    address public override token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public override price0CumulativeLast;
    uint256 public override price1CumulativeLast;
    uint256 public override kLast;

    uint256 private unlocked = 1;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier lock() {
        require(unlocked == 1, "AmmPair: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor() ERC20("Amm LP Token", "AMM-LP") {
        factory = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    /// @inheritdoc IAmmPair
    /// @dev Called exactly once by the factory, immediately after the CREATE2 deployment.
    ///      Tokens are sorted so that `token0 < token1`, which makes pair addresses
    ///      independent of the argument order used by the caller.
    function initialize(address token0_, address token1_) external override {
        require(msg.sender == factory, "AmmPair: FORBIDDEN");
        require(token0_ != address(0) && token1_ != address(0), "AmmPair: ZERO_ADDRESS");
        require(token0_ != token1_, "AmmPair: IDENTICAL_ADDRESSES");
        token0 = token0_;
        token1 = token1_;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IAmmPair
    function getReserves() public view override returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @inheritdoc IAmmPair
    /// @notice Mints LP tokens for the liquidity that was transferred into the pair.
    /// @dev The caller must have transferred both tokens before calling. The amount added is
    ///      derived from the balance delta, not from a parameter, so that fee-on-transfer and
    ///      rebasing tokens cannot desynchronise the accounting.
    function mint(address to) external override lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            // A zero cached reserve with a live supply means one side was drained outside the
            // pair's accounting (rebase-down token, burn, ...). Fail here, loudly, instead of
            // panicking with a division-by-zero below.
            require(_reserve0 > 0 && _reserve1 > 0, "AmmPair: ZERO_RESERVE");
            liquidity = Math.min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }
        require(liquidity > 0, "AmmPair: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @inheritdoc IAmmPair
    /// @notice Burns LP tokens held by the pair itself and returns the underlying tokens.
    /// @dev The caller must transfer the LP tokens to the pair before calling.
    function burn(address to) external override lock returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();

        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "AmmPair: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        IERC20(_token0).safeTransfer(to, amount0);
        IERC20(_token1).safeTransfer(to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // ---------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------

    /// @inheritdoc IAmmPair
    /// @notice Sends `amount0Out` of token0 and/or `amount1Out` of token1 to `to`.
    /// @dev If `data` is non-empty the recipient is called back after receiving the tokens,
    ///      which enables flash swaps: the recipient may use the tokens and repay within the
    ///      same transaction. The repayment is verified by the fee-adjusted invariant below.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external override lock {
        require(amount0Out > 0 || amount1Out > 0, "AmmPair: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "AmmPair: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            // Scope the token addresses so the stack stays shallow in the optimiser.
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "AmmPair: INVALID_TO");
            if (amount0Out > 0) IERC20(_token0).safeTransfer(to, amount0Out);
            if (amount1Out > 0) IERC20(_token1).safeTransfer(to, amount1Out);
            if (data.length > 0) IAmmCallee(to).ammCall(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "AmmPair: INSUFFICIENT_INPUT_AMOUNT");

        {
            // k is checked on fee-adjusted balances: 1000 * b - 3 * in, so that
            // (b0 * 1000 - in0 * 3) * (b1 * 1000 - in1 * 3) >= r0 * r1 * 1000**2
            uint256 balance0Adjusted = balance0 * FEE_DENOMINATOR - amount0In * FEE_NUMERATOR;
            uint256 balance1Adjusted = balance1 * FEE_DENOMINATOR - amount1In * FEE_NUMERATOR;
            require(
                balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * _reserve1 * FEE_DENOMINATOR ** 2,
                "AmmPair: K"
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // ---------------------------------------------------------------------
    // Rescue helpers
    // ---------------------------------------------------------------------

    /// @inheritdoc IAmmPair
    /// @notice Transfers the balance in excess of the cached reserves to `to`.
    /// @dev Recovers tokens that were sent to the pair without going through mint/swap.
    function skim(address to) external override lock {
        address _token0 = token0;
        address _token1 = token1;
        IERC20(_token0).safeTransfer(to, IERC20(_token0).balanceOf(address(this)) - reserve0);
        IERC20(_token1).safeTransfer(to, IERC20(_token1).balanceOf(address(this)) - reserve1);
    }

    /// @inheritdoc IAmmPair
    /// @notice Forces the cached reserves to match the actual balances.
    function sync() external override lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Mints the protocol fee (1/6 of the growth in sqrt(k)) to the fee recipient.
    /// @return feeOn Whether the protocol fee is currently enabled.
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IAmmFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply() * (rootK - rootKLast);
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /// @dev Updates the cached reserves and accumulates the time-weighted prices.
    ///      The price is the amount of token1 per token0 (and vice versa), scaled by 2**112
    ///      and multiplied by the number of seconds elapsed since the last update.
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "AmmPair: OVERFLOW");
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        // Overflow of the uint32 difference is intentional and well defined.
        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
                price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            }
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }
}
