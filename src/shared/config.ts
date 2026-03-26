import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DEFAULT_CONFIG, type PairConfig } from "../types.js";

const CONFIG_DIR = path.join(os.homedir(), ".claude-codex-pair");
const CONFIG_FILE = path.join(CONFIG_DIR, "config.json");

export function getConfigDir(): string {
	return CONFIG_DIR;
}

export function ensureConfigDir(): void {
	if (!fs.existsSync(CONFIG_DIR)) {
		fs.mkdirSync(CONFIG_DIR, { recursive: true });
	}
}

export function loadConfig(): PairConfig {
	ensureConfigDir();
	if (!fs.existsSync(CONFIG_FILE)) return { ...DEFAULT_CONFIG };

	try {
		const raw = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf-8"));
		return { ...DEFAULT_CONFIG, ...raw };
	} catch {
		return { ...DEFAULT_CONFIG };
	}
}

export function saveConfig(config: PairConfig): void {
	ensureConfigDir();
	fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2) + "\n");
}

export function resolveLogDir(config: PairConfig): string {
	const dir = config.logDir.replace("~", os.homedir());
	if (!fs.existsSync(dir)) {
		fs.mkdirSync(dir, { recursive: true });
	}
	return dir;
}
