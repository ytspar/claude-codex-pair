import { describe, it, expect } from "vitest";
import { green, yellow, red, cyan, dim, bold, decisionColor } from "../shared/formatter.js";

describe("formatter", () => {
	describe("color helpers", () => {
		it("wraps text in green ANSI codes", () => {
			expect(green("ok")).toBe("\x1b[32mok\x1b[0m");
		});

		it("wraps text in yellow ANSI codes", () => {
			expect(yellow("warn")).toBe("\x1b[33mwarn\x1b[0m");
		});

		it("wraps text in red ANSI codes", () => {
			expect(red("err")).toBe("\x1b[31merr\x1b[0m");
		});

		it("wraps text in cyan ANSI codes", () => {
			expect(cyan("info")).toBe("\x1b[36minfo\x1b[0m");
		});

		it("wraps text in dim ANSI codes", () => {
			expect(dim("muted")).toBe("\x1b[2mmuted\x1b[0m");
		});

		it("wraps text in bold ANSI codes", () => {
			expect(bold("title")).toBe("\x1b[1mtitle\x1b[0m");
		});

		it("handles empty strings", () => {
			expect(green("")).toBe("\x1b[32m\x1b[0m");
		});
	});

	describe("decisionColor", () => {
		it("colors APPROVE green", () => {
			expect(decisionColor("APPROVE")).toBe(green("APPROVE"));
		});

		it("colors FEEDBACK yellow", () => {
			expect(decisionColor("FEEDBACK")).toBe(yellow("FEEDBACK"));
		});

		it("colors CONTEXT cyan", () => {
			expect(decisionColor("CONTEXT")).toBe(cyan("CONTEXT"));
		});

		it("returns unknown decisions uncolored", () => {
			expect(decisionColor("OTHER")).toBe("OTHER");
		});
	});
});
