import { useEffect, useState } from "react";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { addresses } from "../config/addresses";
import { erc20Abi } from "../config/abi";
import { formatAmount, shortAddress } from "../lib/format";
import { styles } from "../lib/styles";
import { StatRow, TokenChip, useTokenMeta } from "./TokenMeta";

/**
 * Dev faucet. The demo tokens are `MockERC20`, so anyone can mint themselves test balances —
 * without this the UI is unusable on a fresh chain.
 *
 * This panel is intentionally loud about being a development tool: it is not a feature of the
 * protocol, and it only exists because the demo tokens have a public `mint`.
 */
export function FaucetPanel() {
  const { address, isConnected } = useAccount();
  const metaA = useTokenMeta(addresses.tokenA);
  const metaB = useTokenMeta(addresses.tokenB);
  const [error, setError] = useState<string | null>(null);

  const { data: balanceA } = useReadContract({
    address: addresses.tokenA,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: balanceB } = useReadContract({
    address: addresses.tokenB,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) reset();
  }, [isSuccess, reset]);

  useEffect(() => {
    if (writeError) setError(writeError.message.split("\n")[0]);
  }, [writeError]);

  function mint(token: `0x${string}`, amount: bigint) {
    setError(null);
    if (!address) return;
    writeContract({
      address: token,
      abi: erc20Abi,
      functionName: "mint",
      args: [address, amount],
    });
  }

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>
        测试代币水龙头 <span style={{ ...styles.badge, fontSize: 10, marginLeft: 6 }}>DEV ONLY</span>
      </h3>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14 }}>
        <TokenChip token={addresses.tokenA} />
        <TokenChip token={addresses.tokenB} />
      </div>

      <StatRow label={`${metaA.symbol} 余额`} value={formatAmount(balanceA, metaA.decimals)} />
      <StatRow label={`${metaB.symbol} 余额`} value={formatAmount(balanceB, metaB.decimals)} />

      <div style={{ display: "flex", gap: 8, marginTop: 14 }}>
        <button
          style={{ ...styles.buttonSecondary, flex: 1, ...(isConnected && !isPending ? {} : styles.buttonDisabled) }}
          disabled={!isConnected || isPending}
          onClick={() => mint(addresses.tokenA, 10n * 10n ** BigInt(metaA.decimals))}
        >
          +10 {metaA.symbol}
        </button>
        <button
          style={{ ...styles.buttonSecondary, flex: 1, ...(isConnected && !isPending ? {} : styles.buttonDisabled) }}
          disabled={!isConnected || isPending}
          onClick={() => mint(addresses.tokenB, 100_000n * 10n ** BigInt(metaB.decimals))}
        >
          +100k {metaB.symbol}
        </button>
      </div>

      {hash && (
        <div style={styles.success}>
          铸造中：<span style={styles.mono}>{hash.slice(0, 18)}…</span>
          {isConfirming && " （确认中）"}
          {isSuccess && " ✅"}
        </div>
      )}
      {error && <div style={styles.error}>{error}</div>}

      <div style={styles.hint}>
        {metaA.symbol} 是 8 位小数的模拟 BTC，{metaB.symbol} 是 6 位小数的模拟稳定币。
        两者小数位不同，正好用来验证前端与合约在精度上的处理是否一致。
        合约地址 <span style={styles.mono}>{shortAddress(addresses.tokenA)}</span> /{" "}
        <span style={styles.mono}>{shortAddress(addresses.tokenB)}</span>。
      </div>
    </div>
  );
}
