import { useState } from "react";
import { useReadContract } from "wagmi";
import { addresses } from "../config/addresses";
import { factoryAbi, pairAbi } from "../config/abi";
import { formatAmount, shortAddress } from "../lib/format";
import { styles } from "../lib/styles";
import { StatRow } from "./TokenMeta";

/**
 * Contract registry panel: every deployed address in one place, plus a couple of read-only
 * sanity checks. Useful when a reviewer wants to verify the deployment matches the repo without
 * opening a block explorer.
 */
export function ContractsPanel() {
  const { data: pairAddress } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "getPair",
    args: [addresses.tokenA, addresses.tokenB],
  });

  const { data: pairCount } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "allPairsLength",
  });

  const { data: feeTo } = useReadContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: "feeTo",
  });

  const { data: reserves } = useReadContract({
    address: pairAddress as `0x${string}` | undefined,
    abi: pairAbi,
    functionName: "getReserves",
    query: { enabled: Boolean(pairAddress && pairAddress !== "0x0000000000000000000000000000000000000000") },
  });

  const { data: minLiquidity } = useReadContract({
    address: pairAddress as `0x${string}` | undefined,
    abi: pairAbi,
    functionName: "MINIMUM_LIQUIDITY",
    query: { enabled: Boolean(pairAddress && pairAddress !== "0x0000000000000000000000000000000000000000") },
  });

  const [copied, setCopied] = useState<string | null>(null);

  function copy(label: string, value: string) {
    navigator.clipboard?.writeText(value).then(
      () => {
        setCopied(label);
        setTimeout(() => setCopied(null), 1200);
      },
      () => setCopied(null),
    );
  }

  const entries: Array<[string, string]> = [
    ["AmmFactory", addresses.factory],
    ["AmmRouter", addresses.router],
    ["TwapOracle", addresses.oracle],
    ["FlashArbExecutor", addresses.arb],
    ["WETH9", addresses.weth],
    ["TokenA", addresses.tokenA],
    ["TokenB", addresses.tokenB],
  ];

  if (pairAddress && pairAddress !== "0x0000000000000000000000000000000000000000") {
    entries.push(["AmmPair", pairAddress]);
  }

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>合约地址</h3>

      {entries.map(([label, value]) => (
        <div key={label} style={styles.row}>
          <span style={styles.key}>{label}</span>
          <button
            style={{
              background: "none",
              border: "none",
              padding: 0,
              color: copied === label ? "#9df3cb" : "#a9c6ff",
              cursor: "pointer",
              ...styles.mono,
            }}
            onClick={() => copy(label, value)}
            title={value}
          >
            {copied === label ? "已复制" : shortAddress(value)}
          </button>
        </div>
      ))}

      <div style={styles.divider} />

      <StatRow label="交易对总数" value={pairCount !== undefined ? String(pairCount) : "—"} />
      <StatRow label="协议手续费接收方" value={feeTo === "0x0000000000000000000000000000000000000000" ? "未启用" : shortAddress(feeTo)} />
      <StatRow
        label="锁定最小流动性"
        value={minLiquidity !== undefined ? formatAmount(minLiquidity, 18) : "—"}
      />
      <StatRow
        label="储备快照时间"
        value={reserves?.[2] ? new Date(Number(reserves[2]) * 1000).toLocaleTimeString("zh-CN") : "—"}
      />

      <div style={styles.hint}>
        这些地址来自 <code style={styles.mono}>deployments/31337.json</code>，由{" "}
        <code style={styles.mono}>script/Deploy.s.sol</code> 在每次启动时重新生成。
        点击地址即可复制完整值。
      </div>
    </div>
  );
}
