"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { friendly, str, upper, bool, type ActionState } from "@/lib/actions";

export async function createWarehouse(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { count } = await supabase.from("warehouses").select("id", { count: "exact", head: true }).eq("company_id", company.id);
  const { error } = await supabase.from("warehouses").insert({
    company_id: company.id,
    code: upper(fd, "code"),
    name: str(fd, "name"),
    address: str(fd, "address"),
    is_default: bool(fd, "is_default") || (count ?? 0) === 0, // first warehouse becomes main
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/warehouses");
  return { ok: true, message: "Warehouse created." };
}

export async function updateWarehouse(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const id = str(fd, "id");
  const makeDefault = bool(fd, "is_default");
  if (makeDefault) {
    // only one main warehouse per company: clear the old one first
    const { error: e1 } = await supabase.from("warehouses").update({ is_default: false })
      .eq("company_id", company.id).eq("is_default", true).neq("id", id!);
    if (e1) return { error: friendly(e1) };
  }
  const patch: Record<string, unknown> = { name: str(fd, "name"), address: str(fd, "address"), is_active: bool(fd, "is_active") };
  if (makeDefault) patch.is_default = true;
  const { error } = await supabase.from("warehouses").update(patch).eq("id", id!);
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/warehouses");
  return { ok: true, message: "Saved." };
}
