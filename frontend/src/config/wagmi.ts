import { createConfig, http } from "wagmi";
import { defineChain } from "viem";
import { injected } from "wagmi/connectors";

/**
 * Anvil's default chain. Declared explicitly instead of using viem's `foundry` preset so the
 * RPC URL is pinned to the port `dev:all` actually starts.
 */
export const anvil = defineChain({
  id: 31337,
  name: "Anvil Local",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
  },
  blockExplorers: {
    default: { name: "None", url: "http://127.0.0.1:8545" },
  },
  testnet: true,
});

export const wagmiConfig = createConfig({
  chains: [anvil],
  connectors: [injected()],
  transports: {
    [anvil.id]: http("http://127.0.0.1:8545"),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
