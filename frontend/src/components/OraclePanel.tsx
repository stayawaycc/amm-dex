import { useEffect, useState } from "react";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { addresses } from "../config/addresses";
import { factoryAbi, oracleAbi, pairAbi } from "../config/abi";
import { attributeReserves, formatAmount, formatUq112x112, shortAddress } from "../lib/format";
import { styles } from "../lib/styles";
import { StatRow, TokenChip, useTokenMeta } from "./TokenMeta";

/**
 * TWAP oracle panel.
 *
 * Two numbers are shown side by side: the raw accumulator and the last observation snapshot.
 * `consult` needs a full window to have elapsed, so the panel reports the actual blocker instead
 * of a generic failure — that is the single most common source of confusion with this oracle.
 */
export function OraclePanel() {
  const { isConnected } = useAccount();
  const [period, setPeriod] = useState(600);
  const [error, setError] = useState<string | null>(null);

  const { data: pairAddress } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "getPair",
    args: [addresses.tokenA, addresses.tokenB],
  });

  const pair = pairAddress as `0x${string}` | undefined;
  const hasPair = Boolean(pair && pair !== "0x0000000000000000000000000000000000000000");

  const { data: observation } = useReadContract({
    address: addresses.oracle,
    abi: oracleAbi,
    functionName: "observations",
    args: pair ? [pair] : undefined,
    query: { enabled: hasPair },
  });

  const { data: minPeriod } = useReadContract({
    address: addresses.oracle,
    abi: oracleAbi,
    functionName: "MIN_PERIOD",
    query: { staleTime: Infinity },
  });

  const { data: twap, error: twapError } = useReadContract({
    address: addresses.oracle,
    abi: oracleAbi,
    functionName: "consult",
    args: pair ? [pair, period] : undefined,
    query: { enabled: hasPair && Boolean(observation && observation[2] > 0) },
  });

  const { data: price0Cumulative } = useReadContract({
    address: pair,
    abi: pairAbi,
    functionName: "price0CumulativeLast",
    query: { enabled: hasPair },
  });

  const { data: reserves } = useReadContract({
    address: pair,
    abi: pairAbi,
    functionName: "getReserves",
    query: { enabled: hasPair },
  });

  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) reset();
  }, [isSuccess, reset]);

  useEffect(() => {
    if (writeError) setError(writeError.message.split("\n")[0]);
  }, [writeError]);

  const observedAt = observation?.[2] ?? 0;
  const elapsed = observedAt > 0 ? Math.floor(Date.now() / 1000) - observedAt : 0;
  const windowReady = observedAt > 0 && elapsed >= period;

  const metaA = useTokenMeta(addresses.tokenA);
  const metaB = useTokenMeta(addresses.tokenB);

  // Reserves arrive in sorted-address order, so attribute them before computing any ratio.
  const { reserveA, reserveB } = attributeReserves(
    addresses.tokenA,
    addresses.tokenB,
    reserves?.[0],
    reserves?.[1],
  );

  // Spot price of tokenA denominated in tokenB, normalised for the two tokens' decimals.
  // Without the decimal adjustment this prints a meaningless raw-units ratio such as 0.0016.
  const spot =
    reserveA !== undefined && reserveB !== undefined && reserveA > 0n
      ? `${formatAmount((reserveB * 10n ** BigInt(metaA.decimals)) / reserveA, metaB.decimals, 4)} ${metaB.symbol}`
      : "—";

  function handleUpdate() {
    setError(null);
    if (!pair) return;
    writeContract({
      address: addresses.oracle,
      abi: oracleAbi,
      functionName: "update",
      args: [pair],
    });
  }

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>TWAP 预言机</h3>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14 }}>
        <TokenChip token={addresses.tokenA} />
        <TokenChip token={addresses.tokenB} />
      </div>

      <StatRow label={`现货价 (1 ${metaA.symbol})`} value={spot} />
      <StatRow label="累积价格 (原始值)" value={price0Cumulative !== undefined ? formatUq112x112(price0Cumulative, 2) : "—"} />
      <StatRow
        label="观察快照时间"
        value={observedAt > 0 ? new Date(observedAt * 1000).toLocaleString("zh-CN") : "未初始化"}
      />
      <StatRow label="距快照已过" value={observedAt > 0 ? `${elapsed} 秒` : "—"} />

      <div style={styles.divider} />

      <label style={styles.label}>平均窗口（秒）</label>
      <div style={{ display: "flex", gap: 8, marginBottom: 14 }}>
        {[60, 600, 3600, 86400].map((p) => (
          <button
            key={p}
            style={{
              ...styles.buttonSecondary,
              flex: 1,
              fontSize: 12,
              background: period === p ? "rgba(59,111,212,0.3)" : "rgba(255,255,255,0.05)",
            }}
            onClick={() => setPeriod(p)}
          >
            {p >= 3600 ? `${p / 3600}h` : `${p}s`}
          </button>
        ))}
      </div>

      <div
        style={{
          padding: "12px 14px",
          borderRadius: 10,
          background: "rgba(6,10,22,0.6)",
          border: "1px solid rgba(255,255,255,0.09)",
          marginBottom: 12,
        }}
      >
        <div style={{ ...styles.key, marginBottom: 4 }}>TWAP（{period} 秒平均）</div>
        <div style={{ ...styles.value, fontSize: 20, fontWeight: 700, color: twap !== undefined ? "#9df3cb" : "#6f7b96" }}>
          {twap !== undefined ? formatUq112x112(twap, 6) : "—"}
        </div>
      </div>

      {observedAt === 0 && (
        <div style={styles.error}>
          尚未创建观察快照。先点击下方「刷新观察快照」，等满 {period} 秒后再读，才能得到有效的平均值。
        </div>
      )}
      {observedAt > 0 && !windowReady && (
        <div style={styles.error}>
          窗口尚未满足：快照已过 {elapsed} 秒，需要 {period} 秒。再等待 {Math.max(0, period - elapsed)} 秒，或选择更短的窗口。
        </div>
      )}
      {twapError && !windowReady && (
        <div style={{ ...styles.hint, color: "#ffb3b3" }}>{twapError.message.split("\n")[0]}</div>
      )}

      <button
        style={{ ...styles.button, ...(isConnected && hasPair && !isPending ? {} : styles.buttonDisabled), marginTop: 4 }}
        disabled={!isConnected || !hasPair || isPending}
        onClick={handleUpdate}
      >
        {isPending ? "等待确认…" : isConfirming ? "上链中…" : "刷新观察快照（仅 keeper）"}
      </button>

      {hash && (
        <div style={styles.success}>
          快照已更新：<span style={styles.mono}>{hash.slice(0, 18)}…</span>
          {isSuccess && " ✅"}
        </div>
      )}
      {error && <div style={styles.error}>{error}</div>}

      <div style={styles.hint}>
        最小窗口 {minPeriod !== undefined ? String(minPeriod) : "60"} 秒。累积价格只有在池子被触碰时才会推进，
        因此第一次读取前必须先由 keeper 调用 <code style={styles.mono}>update</code> 并等待至少一个完整窗口。
        出于安全考虑（无权限的 update 可被用来重锚观察窗口、永久拒绝服务），update 已收敛为 keeper 专属——
        本地演示部署中 keeper 即部署者账户，切换到其他钱包时该按钮会失败，这是预期行为。
        预言机地址 <span style={styles.mono}>{shortAddress(addresses.oracle)}</span>。
      </div>
    </div>
  );
}
