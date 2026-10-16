"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { friendly, str, upper, type ActionState } from "@/lib/actions";

function fields(fd: FormData) {
  return {
    name: str(fd, "name"),
    number_range_id: str(fd, "number_range_id"),
    default_item_type: str(fd, "default_item_type") ?? "INVENTORY",
    default_procurement_method: str(fd, "default_procurement_method") ?? "BUY",
    default_replenishment_policy: str(fd, "default_replenishment_policy") ?? "TO_ORDER",
    default_uom_group_id: str(fd, "default_uom_group_id"),
  };
}

export async function createItemGroup(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("item_groups").insert({ company_id: company.id, code: upper(fd, "code"), ...fields(fd) });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/item-groups");
  return { ok: true, message: "Item group created." };
}

export async function updateItemGroup(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("item_groups").update(fields(fd)).eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/item-groups");
  return { ok: true, message: "Saved." };
}
