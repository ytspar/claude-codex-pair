import { describe, it, expect } from "vitest";
import { parseCodexResponse } from "../codex/response-parser.js";

describe("parseCodexResponse", () => {
	it("parses APPROVE verdict", () => {
		const result = parseCodexResponse("APPROVE\n\nAll changes look correct.");
		expect(result.decision).toBe("APPROVE");
		expect(result.response).toContain("APPROVE");
	});

	it("parses FEEDBACK verdict", () => {
		const result = parseCodexResponse("FEEDBACK\n\n- Missing error handling in foo.ts");
		expect(result.decision).toBe("FEEDBACK");
		expect(result.response).toContain("Missing error handling");
	});

	it("parses CONTEXT verdict", () => {
		const result = parseCodexResponse("CONTEXT\n\nNeed to see the test files.");
		expect(result.decision).toBe("CONTEXT");
	});

	it("infers FEEDBACK from issue keywords", () => {
		const result = parseCodexResponse("There is an issue with the implementation.");
		expect(result.decision).toBe("FEEDBACK");
	});

	it("defaults to APPROVE for empty response", () => {
		const result = parseCodexResponse("");
		expect(result.decision).toBe("APPROVE");
	});

	it("defaults to APPROVE for ambiguous response", () => {
		const result = parseCodexResponse("Everything looks great, well done.");
		expect(result.decision).toBe("APPROVE");
	});
});
