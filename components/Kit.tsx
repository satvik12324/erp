// Full-kit status of an order (v_sales_order_buffer.kit_status) and of one requirement (v_full_kit_lines).
const ORDER: Record<string, { cls: string; label: string; title: string }> = {
  READY: { cls: "POSTED", label: "ready", title: "Every open line is covered from stock on hand" },
  BUILDABLE: { cls: "DRAFT", label: "buildable", title: "Missing finished units can be made now from components on hand" },
  SHORT: { cls: "neg", label: "short", title: "Something is missing that cannot be made now" },
};

export function KitBadge({ status }: { status: string | null | undefined }) {
  const k = ORDER[status ?? ""];
  if (!k) return null;
  return <span className={`badge ${k.cls}`} title={k.title}>{k.label}</span>;
}

const REQ: Record<string, { cls: string; label: string }> = {
  COVERED: { cls: "POSTED", label: "covered" },
  BUILD: { cls: "DRAFT", label: "build" },
  SHORT: { cls: "neg", label: "short" },
};

export function RequirementBadge({ status }: { status: string }) {
  const k = REQ[status];
  return k ? <span className={`badge ${k.cls}`}>{k.label}</span> : null;
}

export const KIT_ORDER: Record<string, number> = { READY: 0, BUILDABLE: 1, SHORT: 2 };
