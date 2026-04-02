import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ensureConfigDir } from "../shared/config.js";

const CLAUDE_SETTINGS = path.join(os.homedir(), ".claude", "settings.json");

function getHookCommand(filename: string): string {
	const distPath = path.resolve(import.meta.dirname, filename);
	if (fs.existsSync(distPath)) {
		return `node ${distPath}`;
	}
	const srcPath = path.resolve(import.meta.dirname, "..", "..", "src", "monitor", filename.replace(".js", ".ts"));
	return `npx tsx ${srcPath}`;
}

interface ClaudeSettings {
	hooks?: Record<string, Array<{ matcher?: string; hooks: Array<Record<string, unknown>> }>>;
	[key: string]: unknown;
}

function readClaudeSettings(): ClaudeSettings {
	if (!fs.existsSync(CLAUDE_SETTINGS)) return {};
	try {
		return JSON.parse(fs.readFileSync(CLAUDE_SETTINGS, "utf-8"));
	} catch {
		return {};
	}
}

function writeClaudeSettings(settings: ClaudeSettings): void {
	const dir = path.dirname(CLAUDE_SETTINGS);
	if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(CLAUDE_SETTINGS, JSON.stringify(settings, null, 2) + "\n");
}

/**
 * Install the Stop and PermissionRequest hooks into ~/.claude/settings.json.
 * Hooks are added alongside existing hooks  - removal is done by filtering our entries out.
 */
export function installHook(): { installed: boolean; hookCommand: string } {
	ensureConfigDir();
	const settings = readClaudeSettings();

	const hookCommand = getHookCommand("hook-handler.js");
	const permCommand = getHookCommand("permission-handler.js");

	if (!settings.hooks) settings.hooks = {};

	// Install Stop hook
	if (!settings.hooks.Stop) settings.hooks.Stop = [];
	const stopInstalled = settings.hooks.Stop.some((group) =>
		group.hooks?.some((h) => typeof h.command === "string" && h.command.includes("hook-handler")),
	);
	if (!stopInstalled) {
		settings.hooks.Stop.push({
			hooks: [{ type: "command", command: hookCommand, timeout: 600 }],
		});
	}

	// Install PermissionRequest hook (auto-approve during paired sessions)
	if (!settings.hooks.PermissionRequest) settings.hooks.PermissionRequest = [];
	const permInstalled = settings.hooks.PermissionRequest.some((group) =>
		group.hooks?.some((h) => typeof h.command === "string" && h.command.includes("permission-handler")),
	);
	if (!permInstalled) {
		settings.hooks.PermissionRequest.push({
			hooks: [{ type: "command", command: permCommand, timeout: 10 }],
		});
	}

	const installed = !stopInstalled || !permInstalled;
	if (installed) writeClaudeSettings(settings);
	return { installed, hookCommand };
}

/**
 * Remove the Stop hook from ~/.claude/settings.json.
 * Always removes our hook directly  - backup restore is secondary.
 */
export function removeHook(): boolean {
	const settings = readClaudeSettings();
	if (!settings.hooks) return false;

	let removed = false;

	// Remove Stop hook
	if (settings.hooks.Stop) {
		const before = settings.hooks.Stop.length;
		settings.hooks.Stop = settings.hooks.Stop.filter(
			(group) => !group.hooks?.some((h) => typeof h.command === "string" && h.command.includes("hook-handler")),
		);
		if (settings.hooks.Stop.length < before) removed = true;
		if (settings.hooks.Stop.length === 0) delete settings.hooks.Stop;
	}

	// Remove PermissionRequest hook
	if (settings.hooks.PermissionRequest) {
		const before = settings.hooks.PermissionRequest.length;
		settings.hooks.PermissionRequest = settings.hooks.PermissionRequest.filter(
			(group) => !group.hooks?.some((h) => typeof h.command === "string" && h.command.includes("permission-handler")),
		);
		if (settings.hooks.PermissionRequest.length < before) removed = true;
		if (settings.hooks.PermissionRequest.length === 0) delete settings.hooks.PermissionRequest;
	}

	if (settings.hooks && Object.keys(settings.hooks).length === 0) delete settings.hooks;

	writeClaudeSettings(settings);
	return removed;
}

/**
 * Check if our hook is currently installed.
 */
export function isHookInstalled(): boolean {
	const settings = readClaudeSettings();
	return (
		settings.hooks?.Stop?.some((group) =>
			group.hooks?.some((h) => typeof h.command === "string" && h.command.includes("hook-handler")),
		) ?? false
	);
}
