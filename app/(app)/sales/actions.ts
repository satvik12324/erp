"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { friendly, num, str, type ActionState } from "@/lib/actions";

const back = (id: string) => {
  revalidatePath(`/sales/${id}`);
  revalidatePath("/sales/board");
};

export async function createSo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { data, error } = await supabase
    .from("sales_orders")
    .insert({
      company_id: company.id,
      document_type_id: str(fd, "document_type_id"),
      business_partner_id: str(fd, "business_partner_id"),
      doc_date: str(fd, "doc_date"),
      due_date: str(fd, "due_date"),
      time_buffer_days: num(fd, "time_buffer_days"),
      currency_code: str(fd, "currency_code"),
      customer_reference: str(fd, "customer_reference"),
      remarks: str(fd, "remarks"),
    })
    .select("id")
    .single();
  if (error) return { error: friendly(error) };
  redirect(`/sales/${data.id}`);
}

export async function updateSoHeader(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "id")!;
  const draft = str(fd, "status") === "DRAFT";
  const patch: Record<string, unknown> = {
    customer_reference: str(fd, "customer_reference"),
    remarks: str(fd, "remarks"),
    due_date: str(fd, "due_date"),
    time_buffer_days: num(fd, "time_buffer_days"),
  };
  if (draft) {
    patch.doc_date = str(fd, "doc_date");
    patch.currency_code = str(fd, "currency_code");
  }
  const { error } = await supabase.from("sales_orders").update(patch).eq("id", id);
  if (error) return { error: friendly(error) };
  back(id);
  return { ok: true, message: "Saved." };
}

async function setPrice(supabase: any, companyId: string, lineId: string, price: number | null, discount: number | null) {
  if (price === null) return null;
  const { error } = await supabase.from("sales_order_line_prices").upsert(
    { company_id: companyId, sales_order_line_id: lineId, unit_price: price, discount_pct: discount ?? 0 },
    { onConflict: "sales_order_line_id" },
  );
  return error;
}

export async function addSoLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const soId = str(fd, "sales_order_id")!;
  const { data: last } = await supabase.from("sales_order_lines").select("line_no").eq("sales_order_id", soId)
    .order("line_no", { ascending: false }).limit(1);
  const { data: line, error } = await supabase
    .from("sales_order_lines")
    .insert({
      company_id: company.id,
      sales_order_id: soId,
      line_no: (last?.[0]?.line_no ?? 0) + 10,
      item_id: str(fd, "item_id"),
      quantity: num(fd, "quantity"),
      uom_id: str(fd, "uom_id"),
      warehouse_id: str(fd, "warehouse_id"),
      remarks: str(fd, "remarks"),
    })
    .select("id")
    .single();
  if (error) return { error: friendly(error) };
  const e2 = await setPrice(supabase, company.id, line.id, num(fd, "unit_price"), num(fd, "discount_pct"));
  if (e2) return { error: "Line added, but the price was not saved: " + friendly(e2) };
  back(soId);
  return { ok: true };
}

export async function updateSoLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const soId = str(fd, "sales_order_id")!;
  const lineId = str(fd, "id")!;
  const { error } = await supabase.from("sales_order_lines").update({ quantity: num(fd, "quantity") }).eq("id", lineId);
  if (error) return { error: friendly(error) };
  if (fd.has("unit_price")) {
    const e2 = await setPrice(supabase, company.id, lineId, num(fd, "unit_price"), num(fd, "discount_pct"));
    if (e2) return { error: friendly(e2) };
  }
  back(soId);
  return { ok: true };
}

export async function deleteSoLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("sales_order_lines").delete().eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  back(str(fd, "sales_order_id")!);
  return { ok: true };
}

export async function releaseSo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "sales_order_id")!;
  const { data, error } = await supabase.rpc("release_sales_order", { p_so_id: id });
  if (error) return { error: friendly(error) };
  back(id);
  return { ok: true, message: `Released as ${data}.` };
}

export async function closeSo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "sales_order_id")!;
  const { error } = await supabase.rpc("close_sales_order", {
    p_so_id: id, p_reason_id: str(fd, "reason_id"), p_line_id: str(fd, "line_id"),
  });
  if (error) return { error: friendly(error) };
  back(id);
  return { ok: true, message: str(fd, "line_id") ? "Line closed." : "Order closed." };
}

export async function cancelSo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "sales_order_id")!;
  const { error } = await supabase.rpc("cancel_sales_order", { p_so_id: id, p_reason_id: str(fd, "reason_id") });
  if (error) return { error: friendly(error) };
  back(id);
  return { ok: true, message: "Order cancelled." };
}

export async function deleteDraftSo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("sales_orders").delete().eq("id", str(fd, "sales_order_id")!);
  if (error) return { error: friendly(error) };
  redirect("/sales");
}

// Creates a draft delivery for this order's customer and copies the order's open quantities into it.
export async function deliverSo(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const soId = str(fd, "sales_order_id")!;
  const { data: so } = await supabase.from("sales_orders").select("business_partner_id").eq("id", soId).single();
  const typeId = str(fd, "document_type_id");
  if (!typeId) return { error: "No delivery document type exists. Create one under Numbering & doc types (behaves as Delivery)." };
  const { data: doc, error } = await supabase
    .from("inventory_documents")
    .insert({
      company_id: company.id,
      document_type_id: typeId,
      business_partner_id: so?.business_partner_id,
      doc_date: str(fd, "doc_date"),
      reference: str(fd, "reference"),
    })
    .select("id")
    .single();
  if (error) return { error: friendly(error) };
  const { error: e2 } = await supabase.rpc("fill_delivery_from_so", { p_document_id: doc.id, p_so_id: soId });
  if (e2) return { error: friendly(e2) };
  redirect(`/inventory/${doc.id}`);
}
