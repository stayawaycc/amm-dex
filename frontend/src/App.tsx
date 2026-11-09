import { useState } from "react";
import { styles } from "./lib/styles";
import { WalletBar } from "./components/WalletBar";
import { PoolPanel } from "./components/PoolPanel";
import { SwapPanel } from "./components/SwapPanel";
import { LiquidityPanel } from "./components/LiquidityPanel";
import { OraclePanel } from "./components/OraclePanel";
import { FaucetPanel } from "./components/FaucetPanel";
import { ContractsPanel } from "./components/ContractsPanel";

type Tab = "trade" | "oracle" | "dev";

/**
 * Application shell.
 *
 * Three tabs rather than one long page: trading is what a user does, the oracle is what makes
 * the design interesting, and the dev tab is scaffolding. Separating them keeps the main view
 * honest about what the product actually is.
 */
export function App() {
  const [tab, setTab] = useState<Tab>("trade");

  return (
    <div style={styles.app}>
      <div style={styles.container}>
        <header style={styles.header}>
          <div>
            <h1 style={styles.title}>amm-dex</h1>
            <p style={styles.subtitle}>
              恒定乘积做市商 · TWAP 预言机 · 闪电兑换套利 — Solidity 0.8.28 / Foundry
            </p>
          </div>
          <WalletBar />
        </header>

        <nav style={styles.tabs}>
          <button style={styles.tab(tab === "trade")} onClick={() => setTab("trade")}>
            交易
          </button>
          <button style={styles.tab(tab === "oracle")} onClick={() => setTab("oracle")}>
            预言机
          </button>
          <button style={styles.tab(tab === "dev")} onClick={() => setTab("dev")}>
            开发工具
          </button>
        </nav>

        {tab === "trade" && (
          <div style={styles.grid}>
            <SwapPanel />
            <LiquidityPanel />
            <PoolPanel />
          </div>
        )}

        {tab === "oracle" && (
          <div style={styles.grid}>
            <OraclePanel />
            <PoolPanel />
          </div>
        )}

        {tab === "dev" && (
          <div style={styles.grid}>
            <FaucetPanel />
            <ContractsPanel />
          </div>
        )}

        <footer style={{ marginTop: 36, color: "#5b6480", fontSize: 11.5, lineHeight: 1.7 }}>
          <div>
            本地 Anvil 链 · Chain ID 31337 · RPC http://127.0.0.1:8545
          </div>
          <div>
            合约源码与测试见仓库根目录。<code style={styles.mono}>forge test</code> 运行 86 个测试，
            包含不变量模糊测试。
          </div>
        </footer>
      </div>
    </div>
  );
}
