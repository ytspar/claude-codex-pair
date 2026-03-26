const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";

export function green(text: string): string {
	return `${GREEN}${text}${RESET}`;
}
export function yellow(text: string): string {
	return `${YELLOW}${text}${RESET}`;
}
export function red(text: string): string {
	return `${RED}${text}${RESET}`;
}
export function cyan(text: string): string {
	return `${CYAN}${text}${RESET}`;
}
export function dim(text: string): string {
	return `${DIM}${text}${RESET}`;
}
export function bold(text: string): string {
	return `${BOLD}${text}${RESET}`;
}

export function decisionColor(decision: string): string {
	switch (decision) {
		case "APPROVE":
			return green(decision);
		case "FEEDBACK":
			return yellow(decision);
		case "CONTEXT":
			return cyan(decision);
		default:
			return decision;
	}
}
