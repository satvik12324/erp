// Shared helpers for Server Actions.

export type ActionState = { ok?: boolean; error?: string; message?: string };

// Turns database errors into messages a user can act on. Business-rule errors raised by
// our triggers and functions are already written for users and pass through unchanged.
export function friendly(error: { message: string; code?: string } | null | undefined): string {
  if (!error) return "Unknown error";
  const m = error.message;
  if (m.includes("row-level security") || error.code === "42501" && m.startsWith("permission denied"))
    return "You are not authorized for this in the selected company.";
  if (error.code === "23505") {
    if (m.includes("_code_uk") || m.includes("_uk")) return "That code already exists.";
    return "A record with these values already exists.";
  }
  if (error.code === "23503") {
    if (m.includes("update or delete")) return "This record is used elsewhere and cannot be deleted. Set it inactive instead.";
    return "A referenced record does not exist.";
  }
  if (error.code === "23514" && m.includes("_code_format_ck"))
    return "Codes may contain only upper-case letters, digits, '-' and '_' (max 20).";
  return m;
}

export function str(fd: FormData, key: string): string | null {
  const v = fd.get(key);
  if (v === null) return null;
  const s = String(v).trim();
  return s === "" ? null : s;
}

export function num(fd: FormData, key: string): number | null {
  const s = str(fd, key);
  if (s === null) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

export function bool(fd: FormData, key: string): boolean {
  return fd.get(key) === "on" || fd.get(key) === "true";
}

export function upper(fd: FormData, key: string): string | null {
  return str(fd, key)?.toUpperCase() ?? null;
}
