import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { addresses } from "../config/addresses";
import { erc20Abi, routerAbi } from "../config/abi";
import { applySlippage, deadlineInMinutes, formatAmount, parseAmount } from "../lib/format";
import { styles } from "../lib/styles";
import { TokenChip, useTokenMeta } from "./TokenMeta";

/**
 * Swap panel with live quoting and slippage protection.
 *
 * The quote comes from `router.getAmountsOut`, which is the same function the swap itself uses,
 * so what the user sees is exactly what the contract will compute. `amountOutMin` is derived
 * from that quote and the chosen tolerance, and the transaction reverts rather than executing at
 * a worse price.
 */
export function SwapPanel() {
  const { address, isConnected } = useAccount();
  const metaA = useTokenMeta(addresses.tokenA);
  const metaB = useTokenMeta(addresses.tokenB);

  const [direction, setDirection] = useState<"AtoB" | "BtoA">("AtoB");
  const [amountIn, setAmountIn] = useState("");
  const [slippageBps, setSlippageBps] = useState(50);
  const [error, setError] = useState<string | null>(null);

  const tokenIn = direction === "AtoB" ? addresses.tokenA : addresses.tokenB;
  const tokenOut = direction === "AtoB" ? addresses.tokenB : addresses.tokenA;
  const metaIn = direction === "AtoB" ? metaA : metaB;
  const metaOut = direction === "AtoB" ? metaB : metaA;

  const parsedIn = useMemo(() => parseAmount(amountIn, metaIn.decimals), [amountIn, metaIn.decimals]);

  const { data: balanceIn } = useReadContract({
    address: tokenIn,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: allowance } = useReadContract({
    address: tokenIn,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, addresses.router] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: quote } = useReadContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: "getAmountsOut",
    args: parsedIn !== undefined ? [parsedIn, [tokenIn, tokenOut]] : undefined,
    query: { enabled: parsedIn !== undefined && parsedIn > 0n },
  });

  const amountOut = quote?.[1];
  const minOut = amountOut !== undefined ? applySlippage(amountOut, slippageBps) : undefined;
  const needsApproval = parsedIn !== undefined && allowance !== undefined && allowance < parsedIn;

  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) {
      setAmountIn("");
      reset();
    }
  }, [isSuccess, reset]);

  useEffect(() => {
    if (writeError) setError(writeError.message.split("\n")[0]);
  }, [writeError]);

  const canSwap = isConnected && parsedIn !== undefined && parsedIn > 0n && minOut !== undefined && !isPending;

  function handleApprove() {
    setError(null);
    if (parsedIn === undefined) return;
    writeContract({
      address: tokenIn,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.router, parsedIn],
    });
  }

  function handleSwap() {
    setError(null);
    if (parsedIn === undefined || minOut === undefined) return;
    writeContract({
      address: addresses.router,
      abi: routerAbi,
      functionName: "swapExactTokensForTokens",
      args: [parsedIn, minOut, [tokenIn, tokenOut], address!, deadlineInMinutes(20)],
    });
  }

  const priceImpact =
    parsedIn !== undefined && amountOut !== undefined && parsedIn > 0n
      ? (() => {
          // Compare the executed rate against the naive 1:1-of-decimals rate as a rough indicator.
          const scaledIn = Number(parsedIn) / 10 ** metaIn.decimals;
          const scaledOut = Number(amountOut) / 10 ** metaOut.decimals;
          if (scaledIn === 0) return null;
          return scaledOut / scaledIn;
        })()
      : null;

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>兑换</h3>

      <div style={{ display: "flex", gap: 8, marginBottom: 14 }}>
        <button
          style={{ ...styles.toggle(direction === "AtoB"), flex: 1 }}
          onClick={() => setDirection("AtoB")}
        >
          {metaA.symbol} → {metaB.symbol}
        </button>
        <button
          style={{ ...styles.toggle(direction === "BtoA"), flex: 1 }}
          onClick={() => setDirection("BtoA")}
        >
          {metaB.symbol} → {metaA.symbol}
        </button>
      </div>

      <label style={styles.label}>
        支付数量
        {balanceIn !== undefined && (
          <span style={{ float: "right", color: "#6f7b96" }}>
            余额 {formatAmount(balanceIn, metaIn.decimals)} {metaIn.symbol}
          </span>
        )}
      </label>
      <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
        <input
          style={styles.input}
          inputMode="decimal"
          placeholder="0.0"
          value={amountIn}
          onChange={(e) => {
            setAmountIn(e.target.value);
            setError(null);
          }}
        />
        {balanceIn !== undefined && (
          <button
            style={styles.buttonSecondary}
            onClick={() => setAmountIn(formatAmount(balanceIn, metaIn.decimals, metaIn.decimals))}
          >
            最大
          </button>
        )}
      </div>

      <label style={styles.label}>预计获得</label>
      <div
        style={{
          ...styles.input,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          color: amountOut !== undefined ? "#9df3cb" : "#6f7b96",
          marginBottom: 12,
        }}
      >
        <span>{amountOut !== undefined ? formatAmount(amountOut, metaOut.decimals) : "—"}</span>
        <span style={{ fontSize: 12.5, color: "#8b97b3" }}>{metaOut.symbol}</span>
      </div>

      <label style={styles.label}>滑点容忍</label>
      <div style={{ display: "flex", gap: 8, marginBottom: 14 }}>
        {[10, 50, 100, 300].map((bps) => (
          <button
            key={bps}
            style={{
              ...styles.buttonSecondary,
              flex: 1,
              background: slippageBps === bps ? "rgba(59,111,212,0.3)" : "rgba(255,255,255,0.05)",
              fontSize: 12,
            }}
            onClick={() => setSlippageBps(bps)}
          >
            {(bps / 100).toFixed(2)}%
          </button>
        ))}
      </div>

      <div style={{ ...styles.row, borderTop: "1px solid rgba(255,255,255,0.08)", paddingTop: 10 }}>
        <span style={styles.key}>最少获得</span>
        <span style={styles.value}>
          {minOut !== undefined ? `${formatAmount(minOut, metaOut.decimals)} ${metaOut.symbol}` : "—"}
        </span>
      </div>
      {priceImpact !== null && (
        <div style={styles.row}>
          <span style={styles.key}>实际兑换率</span>
          <span style={styles.value}>
            1 {metaIn.symbol} ≈ {priceImpact.toFixed(6)} {metaOut.symbol}
          </span>
        </div>
      )}

      <div style={{ marginTop: 16 }}>
        {needsApproval ? (
          <button style={styles.button} disabled={!canSwap} onClick={handleApprove}>
            {isPending ? "授权中…" : `授权 ${metaIn.symbol}`}
          </button>
        ) : (
          <button style={{ ...styles.button, ...(canSwap ? {} : styles.buttonDisabled) }} disabled={!canSwap} onClick={handleSwap}>
            {!isConnected
              ? "请先连接钱包"
              : isPending
                ? "等待钱包确认…"
                : isConfirming
                  ? "上链中…"
                  : "执行兑换"}
          </button>
        )}
      </div>

      {hash && (
        <div style={styles.success}>
          交易已提交：<span style={styles.mono}>{hash.slice(0, 18)}…</span>
          {isConfirming && " （确认中）"}
          {isSuccess && " ✅ 已完成"}
        </div>
      )}
      {error && <div style={styles.error}>{error}</div>}

      <div style={{ ...styles.hint, display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
        <TokenChip token={tokenIn} /> → <TokenChip token={tokenOut} />
      </div>
    </div>
  );
}
