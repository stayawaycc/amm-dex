import { useReadContract } from "wagmi";
import { addresses } from "../config/addresses";
import { erc20Abi } from "../config/abi";
import { formatAmount, shortAddress } from "../lib/format";
import { styles } from "../lib/styles";

/**
 * Token metadata resolver. Reads symbol and decimals once per token and caches them, so every
 * panel can display amounts correctly without hardcoding decimals anywhere.
 */
export function useTokenMeta(token: `0x${string}`) {
  const { data: symbol } = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "symbol",
    query: { staleTime: Infinity },
  });

  const { data: decimals } = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "decimals",
    query: { staleTime: Infinity },
  });

  const { data: name } = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "name",
    query: { staleTime: Infinity },
  });

  return {
    symbol: symbol ?? "???",
    decimals: decimals ?? 18,
    name: name ?? "Unknown Token",
  };
}

/** A single labelled row inside a card. */
export function StatRow({ label, value }: { label: string; value: string }) {
  return (
    <div style={styles.row}>
      <span style={styles.key}>{label}</span>
      <span style={styles.value}>{value}</span>
    </div>
  );
}

/** Displays a token amount with its symbol. */
export function TokenAmount({ token, amount }: { token: `0x${string}`; amount: bigint | undefined }) {
  const meta = useTokenMeta(token);
  return (
    <span style={styles.value}>
      {formatAmount(amount, meta.decimals)} {meta.symbol}
    </span>
  );
}

/** Compact token identity chip. */
export function TokenChip({ token }: { token: `0x${string}` }) {
  const meta = useTokenMeta(token);
  const isA = token.toLowerCase() === addresses.tokenA.toLowerCase();

  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        padding: "3px 9px",
        borderRadius: 999,
        fontWeight: 600,
        background: isA ? "rgba(255,180,80,0.14)" : "rgba(80,190,255,0.14)",
        border: `1px solid ${isA ? "rgba(255,180,80,0.32)" : "rgba(80,190,255,0.32)"}`,
        color: isA ? "#ffcd8a" : "#9bdcff",
        ...styles.mono,
      }}
      title={token}
    >
      {meta.symbol} · {shortAddress(token)}
    </span>
  );
}
