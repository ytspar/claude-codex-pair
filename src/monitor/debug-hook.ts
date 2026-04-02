#!/usr/bin/env node
/** Temporary debug hook  - logs stdin to a file so we can see what Claude sends */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const LOG = path.join(os.homedir(), ".claude-codex-pair", "hook-debug.json");

let data = "";
process.stdin.setEncoding("utf-8");
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
	fs.mkdirSync(path.dirname(LOG), { recursive: true });
	fs.writeFileSync(LOG, data + "\n", { flag: "a" });
	// Always approve  - don't interfere
	process.stdout.write(JSON.stringify({ decision: "approve" }));
	process.exit(0);
});
