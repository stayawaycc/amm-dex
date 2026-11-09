import { useEffect, useMemo, useState } from "react";
import {
  useAccount,
  useReadContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import { addresses } from "../config/addresses";
import { erc20Abi, factoryAbi, pairAbi, routerAbi } from "../config/abi";
import { applySlippage, attributeReserves, deadlineInMinutes, formatAmount, parseAmount } from "../lib/format";
import { styles } from "../lib/styles";
import { useTokenMeta } from "./TokenMeta";

/**
 * Liquidity panel: add and remove liquidity.
 *
 * The ratio is not enforced client-side beyond display. `router.addLiquidity` rebalances to the
 * pool's current ratio and the caller's minimums are what actually protect them, so the UI shows
 * the expected amounts and lets the contract be the source of truth.
 */
export function LiquidityPanel() {
  const { address, isConnected } = useAccount();
  const metaA = useTokenMeta(addresses.tokenA);
  const metaB = useTokenMeta(addresses.tokenB);

  const [mode, setMode] = useState<"add" | "remove">("add");
  const [amountA, setAmountA] = useState("");
  const [amountB, setAmountB] = useState("");
  const [lpAmount, setLpAmount] = useState("");
  const [slippageBps, setSlippageBps] = useState(50);
  const [error, setError] = useState<string | null>(null);

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

  const { data: lpBalance } = useReadContract({
    address: pair,
    abi: pairAbi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: hasPair && Boolean(address) },
  });

  // LP tokens are ERC-20s too, so the allowance lives on the pair contract, not the router ABI.
  const { data: lpAllowance } = useReadContract({
    address: pair,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, addresses.router] : undefined,
    query: { enabled: hasPair && Boolean(address) },
  });

  const { data: allowanceA } = useReadContract({
    address: addresses.tokenA,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, addresses.router] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: allowanceB } = useReadContract({
    address: addresses.tokenB,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, addresses.router] : undefined,
    query: { enabled: Boolean(address) },
  });

  const parsedA = useMemo(() => parseAmount(amountA, metaA.decimals), [amountA, metaA.decimals]);
  const parsedB = useMemo(() => parseAmount(amountB, metaB.decimals), [amountB, metaB.decimals]);
  const parsedLp = useMemo(() => parseAmount(lpAmount, 18), [lpAmount]);

  const needsApprovalA = parsedA !== undefined && allowanceA !== undefined && allowanceA < parsedA;
  const needsApprovalB = parsedB !== undefined && allowanceB !== undefined && allowanceB < parsedB;
  const needsLpApproval =
    parsedLp !== undefined && typeof lpAllowance === "bigint" && lpAllowance < parsedLp;

  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) {
      setAmountA("");
      setAmountB("");
      setLpAmount("");
      reset();
    }
  }, [isSuccess, reset]);

  useEffect(() => {
    if (writeError) setError(writeError.message.split("\n")[0]);
  }, [writeError]);

  // Reserves come back in sorted-address order; re-attribute them before using them as a ratio.
  const { reserveA, reserveB } = attributeReserves(
    addresses.tokenA,
    addresses.tokenB,
    reserves?.[0],
    reserves?.[1],
  );

  // Hint the matching amount for the second input, based on the pool ratio.
  useEffect(() => {
    if (mode !== "add" || parsedA === undefined || reserveA === undefined || reserveB === undefined) return;
    if (reserveA === 0n) return;
    const implied = (parsedA * reserveB) / reserveA;
    setAmountB(formatAmount(implied, metaB.decimals, metaB.decimals));
  }, [parsedA, reserveA, reserveB, mode, metaB.decimals]);

  function handleApproveA() {
    setError(null);
    if (parsedA === undefined) return;
    writeContract({
      address: addresses.tokenA,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.router, parsedA],
    });
  }

  function handleApproveB() {
    setError(null);
    if (parsedB === undefined) return;
    writeContract({
      address: addresses.tokenB,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.router, parsedB],
    });
  }

  function handleApproveLp() {
    setError(null);
    if (parsedLp === undefined || !pair) return;
    writeContract({
      address: pair,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.router, parsedLp],
    });
  }

  function handleAdd() {
    setError(null);
    if (parsedA === undefined || parsedB === undefined) return;
    writeContract({
      address: addresses.router,
      abi: routerAbi,
      functionName: "addLiquidity",
      args: [
        addresses.tokenA,
        addresses.tokenB,
        parsedA,
        parsedB,
        applySlippage(parsedA, slippageBps),
        applySlippage(parsedB, slippageBps),
        address!,
        deadlineInMinutes(20),
      ],
    });
  }

  function handleRemove() {
    setError(null);
    if (parsedLp === undefined || !pair) return;
    writeContract({
      address: addresses.router,
      abi: routerAbi,
      functionName: "removeLiquidity",
      args: [
        addresses.tokenA,
        addresses.tokenB,
        parsedLp,
        applySlippage(1n, 0),
        applySlippage(1n, 0),
        address!,
        deadlineInMinutes(20),
      ],
    });
  }

  const canAdd =
    isConnected &&
    parsedA !== undefined &&
    parsedA > 0n &&
    parsedB !== undefined &&
    parsedB > 0n &&
    !isPending &&
    !needsApprovalA &&
    !needsApprovalB;

  const canRemove = isConnected && parsedLp !== undefined && parsedLp > 0n && !isPending && !needsLpApproval;

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>流动性</h3>

      <div style={{ display: "flex", gap: 8, marginBottom: 14 }}>
        <button
          style={{ ...styles.toggle(mode === "add"), flex: 1 }}
          onClick={() => setMode("add")}
        >
          添加
        </button>
        <button
          style={{ ...styles.toggle(mode === "remove"), flex: 1 }}
          onClick={() => setMode("remove")}
        >
          移除
        </button>
      </div>

      {mode === "add" ? (
        <>
          <label style={styles.label}>{metaA.symbol} 数量</label>
          <input
            style={{ ...styles.input, marginBottom: 12 }}
            inputMode="decimal"
            placeholder="0.0"
            value={amountA}
            onChange={(e) => setAmountA(e.target.value)}
          />

          <label style={styles.label}>
            {metaB.symbol} 数量
            {reserveA !== undefined && reserveB !== undefined && reserveA > 0n && (
              <span style={{ float: "right", color: "#6f7b96" }}>按池内比例自动匹配</span>
            )}
          </label>
          <input
            style={{ ...styles.input, marginBottom: 12 }}
            inputMode="decimal"
            placeholder="0.0"
            value={amountB}
            onChange={(e) => setAmountB(e.target.value)}
          />

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

          {needsApprovalA || needsApprovalB ? (
            <div style={{ display: "flex", gap: 8 }}>
              {needsApprovalA && (
                <button style={styles.button} disabled={isPending} onClick={handleApproveA}>
                  授权 {metaA.symbol}
                </button>
              )}
              {needsApprovalB && (
                <button style={styles.button} disabled={isPending} onClick={handleApproveB}>
                  授权 {metaB.symbol}
                </button>
              )}
            </div>
          ) : (
            <button style={{ ...styles.button, ...(canAdd ? {} : styles.buttonDisabled) }} disabled={!canAdd} onClick={handleAdd}>
              {!isConnected ? "请先连接钱包" : isPending ? "等待确认…" : isConfirming ? "上链中…" : "添加流动性"}
            </button>
          )}
        </>
      ) : (
        <>
          <label style={styles.label}>
            LP 代币数量
            {lpBalance !== undefined && (
              <span style={{ float: "right", color: "#6f7b96" }}>余额 {formatAmount(lpBalance, 18)}</span>
            )}
          </label>
          <div style={{ display: "flex", gap: 8, marginBottom: 14 }}>
            <input
              style={styles.input}
              inputMode="decimal"
              placeholder="0.0"
              value={lpAmount}
              onChange={(e) => setLpAmount(e.target.value)}
            />
            {lpBalance !== undefined && (
              <button style={styles.buttonSecondary} onClick={() => setLpAmount(formatAmount(lpBalance, 18, 18))}>
                最大
              </button>
            )}
          </div>

          {needsLpApproval ? (
            <button style={styles.button} disabled={isPending} onClick={handleApproveLp}>
              授权 LP 代币
            </button>
          ) : (
            <button
              style={{ ...styles.button, ...(canRemove ? {} : styles.buttonDisabled) }}
              disabled={!canRemove}
              onClick={handleRemove}
            >
              {!isConnected ? "请先连接钱包" : isPending ? "等待确认…" : isConfirming ? "上链中…" : "移除流动性"}
            </button>
          )}

          <div style={styles.hint}>
            移除时返回的两种代币数量由池内储备与 LP 占比决定。合约中的 <code style={styles.mono}>burn</code>{" "}
            始终向下取整，因此池子永远不会多付。
          </div>
        </>
      )}

      {hash && (
        <div style={styles.success}>
          交易已提交：<span style={styles.mono}>{hash.slice(0, 18)}…</span>
          {isConfirming && " （确认中）"}
          {isSuccess && " ✅ 已完成"}
        </div>
      )}
      {error && <div style={styles.error}>{error}</div>}
    </div>
  );
}
