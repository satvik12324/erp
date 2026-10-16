"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { friendly, num, str, type ActionState } from "@/lib/actions";

export async function createDocument(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { data, error } = await supabase
    .from("inventory_documents")
    .insert({
      company_id: company.id,
      document_type_id: str(fd, "document_type_id"),
      doc_date: str(fd, "doc_date"),
      reason_code_id: str(fd, "reason_code_id"),
      reference: str(fd, "reference"),
      remarks: str(fd, "remarks"),
    })
    .select("id")
    .single();
  if (error) return { error: friendly(error) };
  redirect(`/inventory/${data.id}`);
}

export async function updateHeader(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "id")!;
  const { error } = await supabase
    .from("inventory_documents")
    .update({ doc_date: str(fd, "doc_date"), reason_code_id: str(fd, "reason_code_id"), reference: str(fd, "reference"), remarks: str(fd, "remarks") })
    .eq("id", id);
  if (error) return { error: friendly(error) };
  revalidatePath(`/inventory/${id}`);
  return { ok: true, message: "Header saved." };
}

export async function addLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const docId = str(fd, "document_id")!;
  const { data: last } = await supabase
    .from("inventory_document_lines").select("line_no").eq("document_id", docId).order("line_no", { ascending: false }).limit(1);
  const dir = str(fd, "direction");
  const { error } = await supabase.from("inventory_document_lines").insert({
    company_id: company.id,
    document_id: docId,
    line_no: (last?.[0]?.line_no ?? 0) + 10,
    item_id: str(fd, "item_id"),
    quantity: num(fd, "quantity"),
    uom_id: str(fd, "uom_id"),
    warehouse_id: str(fd, "warehouse_id"),
    to_warehouse_id: str(fd, "to_warehouse_id"),
    direction: dir ? Number(dir) : null,
    remarks: str(fd, "remarks"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath(`/inventory/${docId}`);
  return { ok: true };
}

export async function updateLineQty(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase
    .from("inventory_document_lines")
    .update({ quantity: num(fd, "quantity"), warehouse_id: str(fd, "warehouse_id") })
    .eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  revalidatePath(`/inventory/${str(fd, "document_id")}`);
  return { ok: true };
}

export async function deleteLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("inventory_document_lines").delete().eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  revalidatePath(`/inventory/${str(fd, "document_id")}`);
  return { ok: true };
}

export async function fillProduction(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const docId = str(fd, "document_id")!;
  const { error } = await supabase.rpc("fill_production_receipt", {
    p_document_id: docId,
    p_item_id: str(fd, "item_id"),
    p_quantity: num(fd, "quantity"),
    p_uom_id: str(fd, "uom_id"),
    p_warehouse_id: str(fd, "warehouse_id"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath(`/inventory/${docId}`);
  return { ok: true, message: "Lines filled from the BOM. Check warehouses and quantities, then post." };
}

export async function postDocument(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const docId = str(fd, "document_id")!;
  const { data, error } = await supabase.rpc("post_inventory_document", {
    p_document_id: docId,
    p_override_reason_id: str(fd, "override_reason_id"),
  });
  if (error) return { error: friendly(error) + (error.hint ? ` — ${error.hint}` : "") };
  revalidatePath(`/inventory/${docId}`);
  revalidatePath("/stock");
  return { ok: true, message: `Posted as ${data}.` };
}

export async function cancelDocument(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const docId = str(fd, "document_id")!;
  const { data, error } = await supabase.rpc("cancel_inventory_document", {
    p_document_id: docId,
    p_reason_code_id: str(fd, "reason_code_id"),
    p_override_reason_id: str(fd, "override_reason_id"),
  });
  if (error) return { error: friendly(error) + (error.hint ? ` — ${error.hint}` : "") };
  revalidatePath(`/inventory/${docId}`);
  revalidatePath("/stock");
  return { ok: true, message: `Cancelled by ${data}.` };
}

export async function deleteDraft(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("inventory_documents").delete().eq("id", str(fd, "document_id")!);
  if (error) return { error: friendly(error) };
  redirect("/inventory");
}
