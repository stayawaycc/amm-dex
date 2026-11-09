import { useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { styles } from "../lib/styles";
import { shortAddress } from "../lib/format";
import { anvil } from "../config/wagmi";

/**
 * Wallet bar. Deliberately minimal: one injected connector, one chain, one disconnect button.
 * The point of this UI is to demonstrate the contracts, not to be a wallet abstraction layer.
 */
export function WalletBar() {
  const { address, isConnected, chainId } = useAccount();
  const { connectors, connect, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const [showError, setShowError] = useState(false);

  const injectedConnector = connectors.find((c) => c.id === "injected") ?? connectors[0];

  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
      {isConnected ? (
        <>
          <span style={{ ...styles.badge, borderColor: "rgba(120,170,255,0.3)", background: "rgba(59,111,212,0.14)", color: "#a9c6ff" }}>
            {chainId === anvil.id ? "Anvil 31337" : `Chain ${chainId}`}
          </span>
          <span style={{ ...styles.mono, color: "#cfd8ec" }}>{shortAddress(address)}</span>
          {chainId !== anvil.id && (
            <button style={styles.buttonSecondary} onClick={() => switchChain({ chainId: anvil.id })}>
              切到 Anvil
            </button>
          )}
          <button style={styles.buttonSecondary} onClick={() => disconnect()}>
            断开
          </button>
        </>
      ) : (
        <button
          style={{ ...styles.buttonSecondary, padding: "10px 18px" }}
          disabled={isPending || !injectedConnector}
          onClick={() => {
            setShowError(true);
            if (injectedConnector) connect({ connector: injectedConnector });
          }}
        >
          {isPending ? "连接中…" : "连接钱包"}
        </button>
      )}

      {showError && error && (
        <div style={{ ...styles.error, marginTop: 0, maxWidth: 320 }}>
          未检测到浏览器钱包。请安装 MetaMask，并添加网络 RPC http://127.0.0.1:8545 / Chain ID 31337。
        </div>
      )}
    </div>
  );
}
