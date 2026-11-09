#!/usr/bin/env node
/**
 * Deploys the contracts to a local Anvil node, seeds liquidity, and writes the addresses
 * that the frontend reads at runtime.
 *
 * Runs `forge script` twice (deploy, then seed) and waits for the RPC to accept connections
 * before starting, so `npm run dev:all` works from a cold start.
 */
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const RETRIES = 30;

async function rpcReady() {
  for (let i = 0; i < RETRIES; i++) {
    try {
      const res = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      });
      if (res.ok) return true;
    } catch {
      // Node is not up yet.
    }
    await sleep(1000);
  }
  return false;
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: "inherit",
      shell: process.platform === "win32",
      env: {
        ...process.env,
        // A system HTTP proxy would otherwise intercept the localhost RPC call and return 502.
        NO_PROXY: "127.0.0.1,localhost",
        no_proxy: "127.0.0.1,localhost",
        FOUNDRY_DISABLE_NIGHTLY_WARNING: "1",
      },
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with code ${code}`));
    });
  });
}

async function main() {
  process.stdout.write(`[deploy] waiting for ${RPC} ... `);
  if (!(await rpcReady())) {
    console.error("\n[deploy] RPC never came up. Is Anvil running? Try `npm run dev:anvil`.");
    process.exit(1);
  }
  console.log("ready");

  console.log("[deploy] deploying contracts");
  await run("forge", ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--broadcast"]);

  console.log("[deploy] seeding liquidity");
  await run("forge", ["script", "script/SeedLiquidity.s.sol", "--rpc-url", RPC, "--broadcast"]);

  console.log("[deploy] done. Addresses written to deployments/31337.json");
}

main().catch((err) => {
  console.error("[deploy] failed:", err.message);
  process.exit(1);
});
