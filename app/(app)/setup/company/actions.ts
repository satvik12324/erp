"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { bool, friendly, num, str, upper, type ActionState } from "@/lib/actions";

export async function updateCompany(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("companies").update({
    name: str(fd, "name"), legal_name: str(fd, "legal_name"), timezone: str(fd, "timezone"),
    address_line1: str(fd, "address_line1"), address_line2: str(fd, "address_line2"), city: str(fd, "city"),
    region: str(fd, "region"), postal_code: str(fd, "postal_code"), phone: str(fd, "phone"), email: str(fd, "email"),
  }).eq("id", company.id);
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/company");
  return { ok: true, message: "Saved." };
}

export async function updateSettings(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("company_settings").update({
    yellow_from_pct: num(fd, "yellow_from_pct"),
    red_from_pct: num(fd, "red_from_pct"),
    allow_negative_stock: bool(fd, "allow_negative_stock"),
    over_receipt_pct: num(fd, "over_receipt_pct") ?? 0,
  }).eq("company_id", company.id);
  if (error) {
    if (error.message.includes("zones_ck")) return { error: "Yellow must start below red, both between 1 and 100." };
    return { error: friendly(error) };
  }
  revalidatePath("/setup/company");
  return { ok: true, message: "Settings saved." };
}

export async function addRegistration(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("company_registrations").insert({
    company_id: company.id, registration_type: upper(fd, "registration_type"), registration_number: upper(fd, "registration_number"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/company");
  return { ok: true };
}
