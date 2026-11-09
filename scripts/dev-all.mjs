#!/usr/bin/env node
/**
 * One-command local stack: Anvil -> deploy -> seed -> Vite dev server.
 *
 * This is the entry point behind `npm run dev:all`. It exists so a fresh clone works with a
 * single command on Windows, macOS and Linux, without `make`, `bash`, or Docker.
 */
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const isWin = process.platform === "win32";

const baseEnv = {
  ...process.env,
  NO_PROXY: "127.0.0.1,localhost",
  no_proxy: "127.0.0.1,localhost",
  FOUNDRY_DISABLE_NIGHTLY_WARNING: "1",
};

function spawnChild(command, args, opts = {}) {
  return spawn(command, args, { stdio: "inherit", shell: isWin, env: baseEnv, ...opts });
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawnChild(command, args);
    child.on("error", reject);
    child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`))));
  });
}

async function waitForRpc() {
  for (let i = 0; i < 40; i++) {
    try {
      const res = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      });
      if (res.ok) return true;
    } catch {
      // keep waiting
    }
    await sleep(750);
  }
  return false;
}

async function main() {
  console.log("=== amm-dex local stack ===\n");

  console.log("[1/4] starting Anvil on 127.0.0.1:8545");
  const anvil = spawnChild("anvil", ["--port", "8545", "--host", "127.0.0.1"], { stdio: "ignore" });
  anvil.on("error", () => {
    console.error("\n[1/4] Could not start Anvil. Install Foundry and put `anvil` on PATH.");
    process.exit(1);
  });

  if (!(await waitForRpc())) {
    console.error("[1/4] Anvil did not become reachable.");
    anvil.kill();
    process.exit(1);
  }
  console.log("[1/4] Anvil is up\n");

  console.log("[2/4] deploying contracts");
  await run("forge", ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--broadcast"]);
  console.log("[2/4] deployed\n");

  console.log("[3/4] seeding liquidity");
  await run("forge", ["script", "script/SeedLiquidity.s.sol", "--rpc-url", RPC, "--broadcast"]);
  console.log("[3/4] seeded\n");

  console.log("[4/4] starting the frontend dev server");
  const vite = spawnChild("npx", ["vite", "--config", "frontend/vite.config.ts"], { stdio: "inherit" });

  const shutdown = () => {
    vite.kill();
    anvil.kill();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  vite.on("exit", (code) => {
    anvil.kill();
    process.exit(code ?? 0);
  });
}

main().catch((err) => {
  console.error("\ndev:all failed:", err.message);
  process.exit(1);
});
