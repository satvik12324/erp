// Number and status formatting shared by pages.
export const fmt = (n: number | string | null | undefined, digits = 6) =>
  n === null || n === undefined ? "" : Number(n).toLocaleString("en-IN", { maximumFractionDigits: digits });

export const money = (n: number | null | undefined, currency?: string) =>
  n === null || n === undefined
    ? ""
    : `${Number(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}${currency ? " " + currency : ""}`;

// Badge colour class for document statuses (OPEN shows as green like POSTED).
export const statusClass = (s: string) => (s === "OPEN" ? "POSTED" : s);
