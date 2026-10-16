"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { bool, friendly, num, str, upper, type ActionState } from "@/lib/actions";

export async function createAttribute(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("attribute_definitions").insert({
    company_id: company.id,
    code: upper(fd, "code"),
    name: str(fd, "name"),
    data_type: str(fd, "data_type"),
    is_variant_axis: bool(fd, "is_variant_axis"),
  });
  if (error) {
    if (error.message.includes("axis_ck")) return { error: "Only LIST attributes can be variant axes." };
    return { error: friendly(error) };
  }
  revalidatePath("/setup/attributes");
  return { ok: true, message: "Attribute created." };
}

export async function addOption(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("attribute_options").insert({
    company_id: company.id,
    attribute_definition_id: str(fd, "attribute_definition_id"),
    code: upper(fd, "code"),
    name: str(fd, "name"),
    sort_order: num(fd, "sort_order") ?? 0,
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/attributes");
  return { ok: true };
}
