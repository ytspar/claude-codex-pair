import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const SCREENSHOTS_DIR = path.join(os.homedir(), ".claude-codex-pair", "screenshots");

/** Ensure screenshots directory exists */
function ensureDir() {
	fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

/** Generate a timestamped filename */
function screenshotPath(prefix: string, ext = "png"): string {
	const ts = new Date().toISOString().replace(/[:.]/g, "-");
	return path.join(SCREENSHOTS_DIR, `${prefix}-${ts}.${ext}`);
}

/**
 * Capture the entire main screen (silent, no interaction).
 * Uses macOS `screencapture` — works headlessly.
 */
export async function captureScreen(): Promise<string | null> {
	ensureDir();
	const outPath = screenshotPath("screen");
	try {
		await execFileAsync("screencapture", ["-x", "-m", outPath]);
		return fs.existsSync(outPath) ? outPath : null;
	} catch {
		return null;
	}
}

/**
 * Capture a specific window by its window ID.
 * Uses ScreenCaptureKit via a Swift helper (macOS 12.3+).
 * Falls back to `screencapture -l` if SCK isn't available.
 */
export async function captureWindow(windowId: number): Promise<string | null> {
	ensureDir();
	const outPath = screenshotPath(`window-${windowId}`);

	// Try ScreenCaptureKit first (modern macOS, no deprecation warnings)
	const swift = `
import ScreenCaptureKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sem = DispatchSemaphore(value: 0)
Task {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == ${windowId} }) else {
        print("FAIL:window_not_found"); sem.signal(); return
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width) * 2
    config.height = Int(window.frame.height) * 2
    config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let url = URL(fileURLWithPath: "${outPath.replace(/"/g, '\\"')}")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("FAIL:create_dest"); sem.signal(); return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("OK")
    sem.signal()
}
sem.wait()
`;
	try {
		const tmpFile = path.join(os.tmpdir(), "pair-capture-window.swift");
		fs.writeFileSync(tmpFile, swift);
		const { stdout } = await execFileAsync("swift", [tmpFile], { timeout: 10_000 });
		fs.unlinkSync(tmpFile);
		if (stdout.trim() === "OK" && fs.existsSync(outPath)) return outPath;
	} catch { /* fall through */ }

	// Fallback to screencapture -l (needs screen recording permission)
	try {
		await execFileAsync("screencapture", ["-x", "-l", String(windowId), "-o", outPath]);
		return fs.existsSync(outPath) ? outPath : null;
	} catch {
		return null;
	}
}

/**
 * Capture a rectangle region (x, y, width, height). No interaction needed.
 */
export async function captureRegion(
	x: number,
	y: number,
	width: number,
	height: number,
): Promise<string | null> {
	ensureDir();
	const outPath = screenshotPath("region");
	try {
		await execFileAsync("screencapture", ["-x", "-R", `${x},${y},${width},${height}`, outPath]);
		return fs.existsSync(outPath) ? outPath : null;
	} catch {
		return null;
	}
}

/**
 * Find window IDs for a given app name (e.g., "Safari", "Google Chrome").
 * Uses a small Swift snippet via CGWindowListCopyWindowInfo (no Quartz Python needed).
 */
export async function findWindowIds(appName: string): Promise<number[]> {
	const swift = `
import CoreGraphics
import Foundation
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
var ids: [Int] = []
for w in windows {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    if owner.localizedCaseInsensitiveContains("${appName.replace(/"/g, '\\"')}") && layer == 0 {
        if let wid = w[kCGWindowNumber as String] as? Int { ids.append(wid) }
    }
}
print(ids.map(String.init).joined(separator: ","))
`;
	try {
		const tmpFile = path.join(os.tmpdir(), "pair-findwindow.swift");
		fs.writeFileSync(tmpFile, swift);
		const { stdout } = await execFileAsync("swift", [tmpFile], { timeout: 5000 });
		fs.unlinkSync(tmpFile);
		return stdout.trim().split(",").filter(Boolean).map(Number);
	} catch {
		return [];
	}
}

/**
 * Capture a screenshot of a specific app by name.
 * Tries per-window capture first, falls back to full screen.
 */
export async function captureApp(appName: string): Promise<string | null> {
	const windowIds = await findWindowIds(appName);
	if (windowIds.length > 0) {
		const result = await captureWindow(windowIds[0]);
		if (result) return result;
	}
	// Fallback: capture full screen (always works, no special permission)
	return captureScreen();
}

/**
 * Capture a website screenshot using Playwright (if available).
 * Falls back gracefully if Playwright is not installed.
 */
export async function captureWebsite(url: string): Promise<string | null> {
	ensureDir();
	const outPath = screenshotPath("web");

	// Try Playwright via npx (no install required if cached)
	try {
		const script = `
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  await page.goto(${JSON.stringify(url)}, { waitUntil: 'networkidle', timeout: 15000 });
  await page.screenshot({ path: ${JSON.stringify(outPath)}, fullPage: false });
  await browser.close();
})();
`;
		await execFileAsync("node", ["-e", script], { timeout: 30_000 });
		return fs.existsSync(outPath) ? outPath : null;
	} catch {
		// Playwright not available — try a simpler approach with webkit
		return captureWebsiteFallback(url, outPath);
	}
}

/**
 * Fallback: use macOS `webkit2png` or `wkhtml` if available,
 * otherwise return null.
 */
async function captureWebsiteFallback(url: string, outPath: string): Promise<string | null> {
	// Try using macOS's built-in WebKit via a short Swift script
	try {
		const swiftScript = `
import WebKit
import AppKit
let app = NSApplication.shared
let url = URL(string: "${url.replace(/"/g, '\\"')}")!
let config = WKWebViewConfiguration()
let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
view.load(URLRequest(url: url))
DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "${outPath.replace(/"/g, '\\"')}"))
    app.terminate(nil)
}
app.run()
`;
		const tmpScript = path.join(os.tmpdir(), "pair-webshot.swift");
		fs.writeFileSync(tmpScript, swiftScript);
		await execFileAsync("swift", [tmpScript], { timeout: 20_000 });
		fs.unlinkSync(tmpScript);
		return fs.existsSync(outPath) ? outPath : null;
	} catch {
		return null;
	}
}

/**
 * Read a screenshot file as base64 (for embedding in prompts).
 */
export function screenshotToBase64(filePath: string): string | null {
	try {
		const data = fs.readFileSync(filePath);
		return data.toString("base64");
	} catch {
		return null;
	}
}

/**
 * Clean up old screenshots (keep last N).
 */
export function cleanupScreenshots(keepLast = 20): void {
	ensureDir();
	try {
		const files = fs.readdirSync(SCREENSHOTS_DIR)
			.filter(f => f.endsWith(".png"))
			.map(f => ({
				name: f,
				path: path.join(SCREENSHOTS_DIR, f),
				mtime: fs.statSync(path.join(SCREENSHOTS_DIR, f)).mtimeMs,
			}))
			.sort((a, b) => b.mtime - a.mtime);

		for (const file of files.slice(keepLast)) {
			fs.unlinkSync(file.path);
		}
	} catch {
		// ignore cleanup errors
	}
}
