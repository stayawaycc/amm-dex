#!/usr/bin/env node
/**
 * Starts an Anvil node on port 8545 and keeps it alive.
 *
 * Why a Node wrapper instead of calling `anvil` directly from npm:
 *   - npm scripts on Windows cannot reliably background a process and keep it running.
 *   - This script gives a clear error when `anvil` is not on PATH, instead of a cryptic ENOENT.
 *   - It forwards Anvil's output so the developer sees the RPC URL and the funded accounts.
 */
import { spawn } from "node:child_process";

const PORT = process.env.ANVIL_PORT ?? "8545";
const HOST = process.env.ANVIL_HOST ?? "127.0.0.1";

const child = spawn("anvil", ["--port", PORT, "--host", HOST], {
  stdio: "inherit",
  shell: process.platform === "win32",
});

child.on("error", (err) => {
  console.error("\n[anvil] Failed to start Anvil:", err.message);
  console.error("[anvil] Install Foundry first: https://book.getfoundry.sh/getting-started/installation");
  console.error("[anvil] Then make sure `anvil` is on your PATH.\n");
  process.exit(1);
});

child.on("exit", (code) => {
  process.exit(code ?? 0);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    child.kill();
    process.exit(0);
  });
}
