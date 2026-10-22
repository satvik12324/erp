"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { friendly, str, type ActionState } from "@/lib/actions";

// Turns the selected proposal lines into one draft purchase order per supplier (B1: MRP recommendations -> PO).
// Drafts only: the buyer reviews prices and dates, then releases.
export async function createPurchaseOrders(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const selected = fd.getAll("sel").map(String);
  if (selected.length === 0) return { error: "Select at least one line." };
  const typeId = str(fd, "document_type_id");
  if (!typeId) return { error: "No purchase order document type exists. Create one under Numbering & doc types." };

  const bySupplier = new Map<string, { item_id: string; warehouse_id: string; uom_id: string; quantity: number }[]>();
  for (const k of selected) {
    const qty = Number(fd.get(`qty_${k}`));
    if (!(qty > 0)) continue;
    const bp = String(fd.get(`bp_${k}`));
    const list = bySupplier.get(bp) ?? [];
    list.push({ item_id: String(fd.get(`item_${k}`)), warehouse_id: String(fd.get(`wh_${k}`)), uom_id: String(fd.get(`uom_${k}`)), quantity: qty });
    bySupplier.set(bp, list);
  }
  if (bySupplier.size === 0) return { error: "Selected lines have no quantity." };

  const created: string[] = [];
  for (const [bp, lines] of bySupplier) {
    const { data: po, error } = await supabase
      .from("purchase_orders")
      .insert({ company_id: company.id, document_type_id: typeId, business_partner_id: bp, remarks: "From replenishment proposal" })
      .select("id")
      .single();
    if (error) return { error: friendly(error) + (created.length ? ` (${created.length} PO draft(s) already created)` : "") };
    const { error: e2 } = await supabase.from("purchase_order_lines").insert(
      lines.map((l, i) => ({ company_id: company.id, purchase_order_id: po.id, line_no: (i + 1) * 10, ...l })),
    );
    if (e2) return { error: friendly(e2) };
    created.push(po.id);
  }
  revalidatePath("/replenishment");
  revalidatePath("/purchasing");
  if (created.length === 1) redirect(`/purchasing/${created[0]}`);
  return { ok: true, message: `${created.length} draft purchase orders created. Review and release them under Purchase orders.` };
}
