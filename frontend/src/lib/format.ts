/** Formatting helpers shared by every panel. */

/**
 * Formats a raw token amount with its decimals into a compact human string.
 *
 * Two subtleties this handles that a naive `value / 10**decimals` does not:
 *  1. `bigint` division would truncate every fractional part, so the fraction is formatted
 *     separately and only then trimmed.
 *  2. When the amount is far below one whole token (common for LP shares, whose supply is the
 *     square root of two differently-scaled reserves), a fixed fraction width rounds to "0".
 *     In that case we fall back to significant-digit formatting so the number stays readable.
 */
export function formatAmount(value: bigint | undefined, decimals: number, maxFractionDigits = 6): string {
  if (value === undefined) return "—";
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const fraction = abs % base;
  const sign = negative ? "-" : "";

  if (fraction === 0n) return `${sign}${whole.toLocaleString("en-US")}`;

  // Sub-unit amounts. LP share supplies in particular can be astronomically small: for a pool of
  // two tokens with different decimals, `totalSupply = sqrt(reserve0 * reserve1)` is a number
  // whose magnitude depends on both tokens' decimals. Printing 20 leading zeros is unreadable,
  // so anything below 1e-6 switches to scientific notation.
  if (whole === 0n) {
    const fractionStr = fraction.toString().padStart(decimals, "0");
    const leadingZeros = fractionStr.length - fractionStr.replace(/^0+/, "").length;
    const significant = fractionStr.slice(leadingZeros, leadingZeros + Math.max(maxFractionDigits, 1));
    if (significant.length === 0) return "0";
    if (leadingZeros >= 6) {
      const mantissa = `${significant[0]}${significant.length > 1 ? `.${significant.slice(1)}` : ""}`;
      return `${sign}${mantissa}e-${leadingZeros + 1}`;
    }
    return `${sign}0.${"0".repeat(leadingZeros)}${significant}`;
  }

  const fractionStr = fraction.toString().padStart(decimals, "0").slice(0, maxFractionDigits).replace(/0+$/, "");
  return `${sign}${whole.toLocaleString("en-US")}${fractionStr ? `.${fractionStr}` : ""}`;
}

/** Formats a UQ112x112 price into a decimal number, for display only. */
export function formatUq112x112(value: bigint | undefined, fractionDigits = 6): string {
  if (value === undefined) return "—";
  const Q112 = 1n << 112n;
  const whole = value / Q112;
  const fraction = ((value % Q112) * 10n ** BigInt(fractionDigits)) / Q112;
  const fractionStr = fraction.toString().padStart(fractionDigits, "0");
  return `${whole.toLocaleString("en-US")}.${fractionStr}`;
}

/** Parses a user-typed decimal string into a raw token amount, without floating point. */
export function parseAmount(input: string, decimals: number): bigint | undefined {
  const trimmed = input.trim();
  if (trimmed === "" || trimmed === ".") return undefined;
  if (!/^\d*\.?\d*$/.test(trimmed)) return undefined;

  const [whole = "0", fraction = ""] = trimmed.split(".");
  if (fraction.length > decimals) return undefined;

  const padded = fraction.padEnd(decimals, "0");
  try {
    return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
  } catch {
    return undefined;
  }
}

/** Shortens an address for display: 0x1234…abcd. */
export function shortAddress(address: string | undefined): string {
  if (!address) return "—";
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/** Applies a slippage tolerance in basis points, rounding down. */
export function applySlippage(amount: bigint, bps: number): bigint {
  return (amount * BigInt(10_000 - bps)) / 10_000n;
}

/** A deadline N minutes from now, as a unix timestamp. */
export function deadlineInMinutes(minutes = 20): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + minutes * 60);
}

/**
 * Maps `AmmPair.getReserves()` output onto the caller's own tokenA / tokenB naming.
 *
 * `getReserves()` always returns `(reserve0, reserve1)` in **sorted address order**, which has
 * nothing to do with the order the caller thinks in. A caller that wants "the balance of tokenA"
 * must translate, and getting this backwards silently displays the wrong token's balance while
 * still looking plausible — which is exactly the kind of bug that survives review.
 *
 * @param tokenA The caller's first token (arbitrary, not necessarily the lower address).
 * @param tokenB The caller's second token.
 * @param reserve0 The first value returned by `getReserves()`, i.e. the token0 reserve.
 * @param reserve1 The second value returned by `getReserves()`, i.e. the token1 reserve.
 */
export function attributeReserves(
  tokenA: `0x${string}`,
  tokenB: `0x${string}`,
  reserve0: bigint | undefined,
  reserve1: bigint | undefined,
): { reserveA: bigint | undefined; reserveB: bigint | undefined; aIsToken0: boolean } {
  const aIsToken0 = tokenA.toLowerCase() < tokenB.toLowerCase();
  return {
    reserveA: aIsToken0 ? reserve0 : reserve1,
    reserveB: aIsToken0 ? reserve1 : reserve0,
    aIsToken0,
  };
}
