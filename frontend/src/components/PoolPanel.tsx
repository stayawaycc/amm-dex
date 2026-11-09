import { useReadContract } from "wagmi";
import { addresses } from "../config/addresses";
import { factoryAbi, pairAbi, oracleAbi } from "../config/abi";
import { attributeReserves, formatAmount, formatUq112x112, shortAddress } from "../lib/format";
import { styles } from "../lib/styles";
import { StatRow, TokenChip, useTokenMeta } from "./TokenMeta";

/**
 * Pool overview: reserves, implied spot price, LP supply, and the TWAP accumulator state.
 *
 * The point of this panel is to make the difference between spot and time-weighted price visible
 * side by side, because that difference is the core idea of the project.
 */
export function PoolPanel() {
  const { data: pairAddress } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "getPair",
    args: [addresses.tokenA, addresses.tokenB],
  });

  const pair = pairAddress as `0x${string}` | undefined;
  const hasPair = Boolean(pair && pair !== "0x0000000000000000000000000000000000000000");

  const { data: reserves } = useReadContract({
    address: pair,
    abi: pairAbi,
    functionName: "getReserves",
    query: { enabled: hasPair },
  });

  const { data: totalSupply } = useReadContract({
    address: pair,
    abi: pairAbi,
    functionName: "totalSupply",
    query: { enabled: hasPair },
  });

  const { data: price0Cumulative } = useReadContract({
    address: pair,
    abi: pairAbi,
    functionName: "price0CumulativeLast",
    query: { enabled: hasPair },
  });

  const { data: observation } = useReadContract({
    address: addresses.oracle,
    abi: oracleAbi,
    functionName: "observations",
    args: pair ? [pair] : undefined,
    query: { enabled: hasPair },
  });

  const metaA = useTokenMeta(addresses.tokenA);
  const metaB = useTokenMeta(addresses.tokenB);

  // `getReserves` returns amounts in sorted-address order, so they must be attributed to
  // tokenA / tokenB explicitly. Skipping this silently swaps the two displayed balances.
  const { reserveA, reserveB } = attributeReserves(
    addresses.tokenA,
    addresses.tokenB,
    reserves?.[0],
    reserves?.[1],
  );

  // Implied spot price of tokenA in tokenB, computed with BigInt to avoid precision loss.
  const spotPrice =
    reserveA !== undefined && reserveB !== undefined && reserveA > 0n
      ? formatAmount((reserveB * 10n ** BigInt(metaA.decimals)) / reserveA, metaB.decimals, 4)
      : "—";

  const lastObservation = observation?.[2] ?? 0;

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>资金池状态</h3>

      {!hasPair ? (
        <div style={{ ...styles.hint, color: "#ffb3b3" }}>
          尚未创建 {metaA.symbol}/{metaB.symbol} 交易对。请先运行 <code style={styles.mono}>npm run dev:deploy</code>。
        </div>
      ) : (
        <>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14 }}>
            <TokenChip token={addresses.tokenA} />
            <TokenChip token={addresses.tokenB} />
          </div>

          <StatRow label={`储备 ${metaA.symbol}`} value={formatAmount(reserveA, metaA.decimals)} />
          <StatRow label={`储备 ${metaB.symbol}`} value={formatAmount(reserveB, metaB.decimals)} />
          <StatRow label="LP 总供应量" value={formatAmount(totalSupply, 18, 8)} />
          <StatRow label={`现货价 (1 ${metaA.symbol})`} value={`${spotPrice} ${metaB.symbol}`} />

          <div style={styles.divider} />

          <StatRow label="累积价格 (price0)" value={formatUq112x112(price0Cumulative, 4)} />
          <StatRow
            label="最后观察时间"
            value={lastObservation > 0 ? new Date(lastObservation * 1000).toLocaleString("zh-CN") : "尚未初始化"}
          />
          <StatRow label="交易对地址" value={shortAddress(pair)} />

          <div style={styles.hint}>
            TWAP 预言机读取的是累积价格对时间的平均。现货价可以被单笔闪电贷在同一个区块内推动，
            累积价格不能——这是本项目中价格安全的根本原因。
          </div>
        </>
      )}
    </div>
  );
}
