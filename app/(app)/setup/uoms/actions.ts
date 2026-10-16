"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { friendly, num, str, upper, type ActionState } from "@/lib/actions";

export async function createUom(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("uoms").insert({
    company_id: company.id, code: upper(fd, "code"), name: str(fd, "name"), decimals: num(fd, "decimals") ?? 0,
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/uoms");
  return { ok: true, message: "Unit created." };
}

export async function createUomGroup(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("uom_groups").insert({
    company_id: company.id, code: upper(fd, "code"), name: str(fd, "name"), base_uom_id: str(fd, "base_uom_id"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/uoms");
  return { ok: true, message: "UoM group created." };
}

export async function addConversion(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("uom_group_conversions").insert({
    company_id: company.id,
    uom_group_id: str(fd, "uom_group_id"),
    alt_uom_id: str(fd, "alt_uom_id"),
    alt_qty: num(fd, "alt_qty") ?? 1,
    base_qty: num(fd, "base_qty"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/uoms");
  return { ok: true };
}

export async function deleteConversion(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("uom_group_conversions").delete().eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/uoms");
  return { ok: true };
}
