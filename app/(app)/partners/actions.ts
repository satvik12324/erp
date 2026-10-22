"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { bool, friendly, num, str, upper, type ActionState } from "@/lib/actions";

function bpFields(fd: FormData) {
  return {
    name: str(fd, "name"),
    bp_type: str(fd, "bp_type"),
    currency_code: str(fd, "currency_code"),
    payment_terms: str(fd, "payment_terms"),
    default_lead_time_days: num(fd, "default_lead_time_days"),
    phone: str(fd, "phone"),
    email: str(fd, "email"),
    notes: str(fd, "notes"),
  };
}

export async function createPartner(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { data, error } = await supabase
    .from("business_partners")
    .insert({ company_id: company.id, code: upper(fd, "code"), ...bpFields(fd) })
    .select("id")
    .single();
  if (error) return { error: friendly(error) };
  redirect(`/partners/${data.id}`);
}

export async function updatePartner(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "id")!;
  const { error } = await supabase.from("business_partners").update({ ...bpFields(fd), is_active: bool(fd, "is_active") }).eq("id", id);
  if (error) return { error: friendly(error) };
  revalidatePath(`/partners/${id}`);
  return { ok: true, message: "Saved." };
}

export async function addAddress(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const bp = str(fd, "business_partner_id")!;
  const { error } = await supabase.from("bp_addresses").insert({
    company_id: company.id, business_partner_id: bp, address_type: str(fd, "address_type"), label: str(fd, "label"),
    line1: str(fd, "line1"), line2: str(fd, "line2"), city: str(fd, "city"), region: str(fd, "region"),
    postal_code: str(fd, "postal_code"), country_code: upper(fd, "country_code"), is_default: bool(fd, "is_default"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath(`/partners/${bp}`);
  return { ok: true };
}

export async function addContact(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const bp = str(fd, "business_partner_id")!;
  const { error } = await supabase.from("bp_contacts").insert({
    company_id: company.id, business_partner_id: bp, name: str(fd, "name"), role: str(fd, "role"),
    phone: str(fd, "phone"), email: str(fd, "email"), is_primary: bool(fd, "is_primary"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath(`/partners/${bp}`);
  return { ok: true };
}

export async function addRegistration(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const bp = str(fd, "business_partner_id")!;
  const { error } = await supabase.from("bp_registrations").insert({
    company_id: company.id, business_partner_id: bp, registration_type: upper(fd, "registration_type"),
    registration_number: upper(fd, "registration_number"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath(`/partners/${bp}`);
  return { ok: true };
}

export async function deleteChild(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const table = str(fd, "table");
  if (!["bp_addresses", "bp_contacts", "bp_registrations"].includes(table ?? "")) return { error: "Invalid table" };
  const { error } = await supabase.from(table!).delete().eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  revalidatePath(`/partners/${str(fd, "business_partner_id")}`);
  return { ok: true };
}

// Item-supplier rows can be maintained from the partner page and from the item page.
export async function upsertItemSupplier(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const row = {
    company_id: company.id,
    item_id: str(fd, "item_id"),
    business_partner_id: str(fd, "business_partner_id"),
    supplier_item_code: str(fd, "supplier_item_code"),
    purchase_uom_id: str(fd, "purchase_uom_id"),
    min_order_qty: num(fd, "min_order_qty"),
    order_multiple: num(fd, "order_multiple"),
    lead_time_days: num(fd, "lead_time_days"),
    is_preferred: bool(fd, "is_preferred"),
  };
  if (row.is_preferred) {
    await supabase.from("item_suppliers").update({ is_preferred: false })
      .eq("item_id", row.item_id!).eq("is_preferred", true).neq("business_partner_id", row.business_partner_id!);
  }
  const { error } = await supabase.from("item_suppliers").upsert(row, { onConflict: "item_id,business_partner_id" });
  if (error) return { error: friendly(error) };
  revalidatePath(`/partners/${row.business_partner_id}`);
  revalidatePath(`/items/${row.item_id}`);
  return { ok: true, message: "Saved." };
}

export async function deleteItemSupplier(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("item_suppliers").delete().eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  revalidatePath(`/partners/${str(fd, "business_partner_id")}`);
  revalidatePath(`/items/${str(fd, "item_id")}`);
  return { ok: true };
}
