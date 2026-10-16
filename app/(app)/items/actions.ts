"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { bool, friendly, num, str, type ActionState } from "@/lib/actions";

function itemFields(fd: FormData) {
  return {
    name: str(fd, "name"),
    description: str(fd, "description"),
    item_type: str(fd, "item_type"),
    procurement_method: str(fd, "procurement_method"),
    replenishment_policy: str(fd, "replenishment_policy"),
    inventory_uom_id: str(fd, "inventory_uom_id"),
    purchase_uom_id: str(fd, "purchase_uom_id"),
    sales_uom_id: str(fd, "sales_uom_id"),
    default_warehouse_id: str(fd, "default_warehouse_id"),
    is_purchased: bool(fd, "is_purchased"),
    is_sold: bool(fd, "is_sold"),
  };
}

export async function createItem(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const row = {
    company_id: company.id,
    item_code: str(fd, "item_code")?.toUpperCase() ?? null,
    item_group_id: str(fd, "item_group_id"),
    uom_group_id: str(fd, "uom_group_id"),
    is_template: bool(fd, "is_template"),
    ...itemFields(fd),
  };
  const { data, error } = await supabase.from("items").insert(row).select("id").single();
  if (error) return { error: friendly(error) };
  redirect(`/items/${data.id}`);
}

export async function updateItem(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const id = str(fd, "id")!;
  const patch: Record<string, unknown> = { ...itemFields(fd), is_active: bool(fd, "is_active") };
  // keep NOT NULL columns untouched when left blank
  for (const k of ["item_type", "procurement_method", "replenishment_policy", "inventory_uom_id", "purchase_uom_id", "sales_uom_id"])
    if (patch[k] === null) delete patch[k];
  const { error } = await supabase.from("items").update(patch).eq("id", id);
  if (error) return { error: friendly(error) };
  revalidatePath(`/items/${id}`);
  return { ok: true, message: "Saved." };
}

export async function setAttribute(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const itemId = str(fd, "item_id")!;
  const defId = str(fd, "attribute_definition_id")!;
  const type = str(fd, "data_type");
  const value = str(fd, "value");
  if (value === null) {
    const { error } = await supabase.from("item_attribute_values").delete().eq("item_id", itemId).eq("attribute_definition_id", defId);
    if (error) return { error: friendly(error) };
  } else {
    const { error } = await supabase.from("item_attribute_values").upsert(
      {
        company_id: company.id,
        item_id: itemId,
        attribute_definition_id: defId,
        option_id: type === "LIST" ? value : null,
        text_value: type === "TEXT" ? value : null,
        number_value: type === "NUMBER" ? Number(value) : null,
      },
      { onConflict: "item_id,attribute_definition_id" },
    );
    if (error) return { error: friendly(error) };
  }
  revalidatePath(`/items/${itemId}`);
  return { ok: true };
}

// Creates a variant of a template: copies the template's settings, then sets the variant-axis values.
export async function createVariant(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const templateId = str(fd, "template_item_id")!;
  const { data: t, error: e0 } = await supabase.from("items").select("*").eq("id", templateId).single();
  if (e0 || !t) return { error: friendly(e0) };

  const { data: v, error: e1 } = await supabase
    .from("items")
    .insert({
      company_id: company.id,
      item_code: str(fd, "item_code")?.toUpperCase() ?? null,
      name: str(fd, "name") ?? t.name,
      item_group_id: t.item_group_id,
      item_type: t.item_type,
      procurement_method: t.procurement_method,
      replenishment_policy: t.replenishment_policy,
      uom_group_id: t.uom_group_id,
      inventory_uom_id: t.inventory_uom_id,
      purchase_uom_id: t.purchase_uom_id,
      sales_uom_id: t.sales_uom_id,
      default_warehouse_id: t.default_warehouse_id,
      is_purchased: t.is_purchased,
      is_sold: t.is_sold,
      template_item_id: templateId,
    })
    .select("id")
    .single();
  if (e1) return { error: friendly(e1) };

  const values = [...fd.entries()]
    .filter(([k, val]) => k.startsWith("axis:") && String(val) !== "")
    .map(([k, val]) => ({ company_id: company.id, item_id: v.id, attribute_definition_id: k.slice(5), option_id: String(val) }));
  if (values.length > 0) {
    const { error: e2 } = await supabase.from("item_attribute_values").insert(values);
    if (e2) {
      await supabase.from("items").delete().eq("id", v.id); // undo: variant without its attributes is useless
      return { error: friendly(e2) };
    }
  }
  revalidatePath(`/items/${templateId}`);
  return { ok: true, message: "Variant created." };
}

export async function createBom(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const itemId = str(fd, "item_id")!;
  const { error } = await supabase.from("bom_headers").insert({
    company_id: company.id, item_id: itemId, base_quantity: num(fd, "base_quantity") ?? 1, uom_id: str(fd, "uom_id"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath(`/items/${itemId}`);
  return { ok: true };
}

export async function addBomLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const bomId = str(fd, "bom_id")!;
  const componentId = str(fd, "component_item_id");
  let uomId = str(fd, "uom_id");
  if (!uomId && componentId) {
    const { data } = await supabase.from("items").select("inventory_uom_id").eq("id", componentId).single();
    uomId = data?.inventory_uom_id ?? null;
  }
  const { data: last } = await supabase.from("bom_lines").select("line_no").eq("bom_id", bomId).order("line_no", { ascending: false }).limit(1);
  const { error } = await supabase.from("bom_lines").insert({
    company_id: company.id,
    bom_id: bomId,
    line_no: num(fd, "line_no") ?? ((last?.[0]?.line_no ?? 0) + 10),
    component_item_id: componentId,
    quantity: num(fd, "quantity"),
    uom_id: uomId,
    issue_method: str(fd, "issue_method") ?? "BACKFLUSH",
    issue_warehouse_id: str(fd, "issue_warehouse_id"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath(`/items/${str(fd, "item_id")}`);
  return { ok: true };
}

export async function deleteBomLine(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.from("bom_lines").delete().eq("id", str(fd, "id")!);
  if (error) return { error: friendly(error) };
  revalidatePath(`/items/${str(fd, "item_id")}`);
  return { ok: true };
}
