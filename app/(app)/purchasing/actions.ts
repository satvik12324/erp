"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { friendly, num, str, type ActionState } from "@/lib/actions";

const back = (id: string) => revalidatePath(`/purchasing/${id}`);

export async function createPo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { data, error } = await supabase
    .from("purchase_orders")
    .insert({
      company_id: company.id,
      document_type_id: str(fd, "document_type_id"),
      business_partner_id: str(fd, "business_partner_id"),
      doc_date: str(fd, "doc_date"),
      required_date: str(fd, "required_date"),
      currency_code: str(fd, "currency_code"),
      supplier_reference: str(fd, "supplier_reference"),
      remarks: str(fd, "remarks"),
    })
    .select("id")
    .single();
  if (error) return { error: friendly(error) };
  redirect(`/purchasing/${data.id}`);
}

export async function updatePoHeader(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "id")!;
  const draft = str(fd, "status") === "DRAFT";
  const patch: Record<string, unknown> = {
    supplier_reference: str(fd, "supplier_reference"),
    remarks: str(fd, "remarks"),
    required_date: str(fd, "required_date"),
  };
  if (draft) {
    patch.doc_date = str(fd, "doc_date");
    patch.currency_code = str(fd, "currency_code");
  }
  const { error } = await supabase.from("purchase_orders").update(patch).eq("id", id);
  if (error) return { error: friendly(error) };
  back(id);
  return { ok: true, message: "Saved." };
}

async function setPrice(supabase: any, companyId: string, lineId: string, price: number | null, discount: number | null) {
  if (price === null) return null;
  const { error } = await supabase.from("purchase_order_line_prices").upsert(
    { company_id: companyId, purchase_order_line_id: lineId, unit_price: price, discount_pct: discount ?? 0 },
    { onConflict: "purchase_order_line_id" },
  );
  return error;
}

export async function addPoLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const poId = str(fd, "purchase_order_id")!;
  const { data: last } = await supabase.from("purchase_order_lines").select("line_no").eq("purchase_order_id", poId)
    .order("line_no", { ascending: false }).limit(1);
  const { data: line, error } = await supabase
    .from("purchase_order_lines")
    .insert({
      company_id: company.id,
      purchase_order_id: poId,
      line_no: (last?.[0]?.line_no ?? 0) + 10,
      item_id: str(fd, "item_id"),
      quantity: num(fd, "quantity"),
      uom_id: str(fd, "uom_id"),
      warehouse_id: str(fd, "warehouse_id"),
      required_date: str(fd, "required_date"),
      expected_date: str(fd, "expected_date"),
    })
    .select("id")
    .single();
  if (error) return { error: friendly(error) };
  const e2 = await setPrice(supabase, company.id, line.id, num(fd, "unit_price"), num(fd, "discount_pct"));
  if (e2) return { error: "Line added, but the price was not saved: " + friendly(e2) };
  back(poId);
  return { ok: true };
}

export async function updatePoLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const poId = str(fd, "purchase_order_id")!;
  const lineId = str(fd, "id")!;
  const { error } = await supabase
    .from("purchase_order_lines")
    .update({
      quantity: num(fd, "quantity"),
      required_date: str(fd, "required_date"),
      expected_date: str(fd, "expected_date"),
    })
    .eq("id", lineId);
  if (error) return { error: friendly(error) };
  if (fd.has("unit_price")) {
    const e2 = await setPrice(supabase, company.id, lineId, num(fd, "unit_price"), num(fd, "discount_pct"));
    if (e2) return { error: friendly(e2) };
  }
  back(poId);
  return { ok: true };
}

export async function deletePoLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("purchase_order_lines").delete().eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  back(str(fd, "purchase_order_id")!);
  return { ok: true };
}

export async function releasePo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "purchase_order_id")!;
  const { data, error } = await supabase.rpc("release_purchase_order", { p_po_id: id });
  if (error) return { error: friendly(error) };
  back(id);
  return { ok: true, message: `Released as ${data}.` };
}

export async function closePo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "purchase_order_id")!;
  const { error } = await supabase.rpc("close_purchase_order", {
    p_po_id: id, p_reason_id: str(fd, "reason_id"), p_line_id: str(fd, "line_id"),
  });
  if (error) return { error: friendly(error) };
  back(id);
  return { ok: true, message: str(fd, "line_id") ? "Line closed." : "PO closed." };
}

export async function cancelPo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "purchase_order_id")!;
  const { error } = await supabase.rpc("cancel_purchase_order", { p_po_id: id, p_reason_id: str(fd, "reason_id") });
  if (error) return { error: friendly(error) };
  back(id);
  return { ok: true, message: "PO cancelled." };
}

export async function deleteDraftPo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("purchase_orders").delete().eq("id", str(fd, "purchase_order_id")!);
  if (error) return { error: friendly(error) };
  redirect("/purchasing");
}

// Creates a draft goods receipt PO for this PO's supplier and copies the PO's open quantities into it.
export async function receivePo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const poId = str(fd, "purchase_order_id")!;
  const { data: po } = await supabase.from("purchase_orders").select("business_partner_id").eq("id", poId).single();
  const typeId = str(fd, "document_type_id");
  if (!typeId) return { error: "No goods receipt PO document type exists. Create one under Numbering & doc types." };
  const { data: doc, error } = await supabase
    .from("inventory_documents")
    .insert({
      company_id: company.id,
      document_type_id: typeId,
      business_partner_id: po?.business_partner_id,
      doc_date: str(fd, "doc_date"),
      reference: str(fd, "reference"),
    })
    .select("id")
    .single();
  if (error) return { error: friendly(error) };
  const { error: e2 } = await supabase.rpc("fill_receipt_from_po", { p_document_id: doc.id, p_po_id: poId });
  if (e2) return { error: friendly(e2) };
  redirect(`/inventory/${doc.id}`);
}
