import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { ItemFields } from "@/components/ItemFields";
import { createItem } from "../actions";

export default async function NewItemPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: groups }, { data: uomGroups }, { data: uoms }, { data: warehouses }] = await Promise.all([
    supabase.from("item_groups").select("id, code, name, number_range_id").eq("company_id", company.id).eq("is_active", true).order("code"),
    supabase.from("uom_groups").select("id, code, name").eq("company_id", company.id).eq("is_active", true).order("code"),
    supabase.from("uoms").select("id, code").eq("company_id", company.id).order("code"),
    supabase.from("warehouses").select("id, code, name").eq("company_id", company.id).eq("is_active", true).order("code"),
  ]);

  return (
    <section>
      <h1>New item</h1>
      <p className="muted">Leave the code empty when the item group has a numbering series. Empty selects take the item group&apos;s defaults.</p>
      <div className="panel">
        <ActionForm action={createItem} resetOnSuccess={false}>
          <div className="form-grid" style={{ marginBottom: 10 }}>
            <label>Item group
              <select name="item_group_id" required>
                {(groups ?? []).map((g) => (
                  <option key={g.id} value={g.id}>{g.code} · {g.name}{g.number_range_id ? " (auto code)" : ""}</option>
                ))}
              </select>
            </label>
            <label>Item code<input name="item_code" maxLength={50} className="mono" placeholder="auto" /></label>
            <label>UoM group
              <select name="uom_group_id" defaultValue="">
                <option value="">From item group</option>
                {(uomGroups ?? []).map((u) => <option key={u.id} value={u.id}>{u.code} · {u.name}</option>)}
              </select>
            </label>
            <label className="check"><input type="checkbox" name="is_template" />Template (has variants, never stocked)</label>
          </div>
          <ItemFields uoms={uoms ?? []} warehouses={warehouses ?? []} />
          <p style={{ marginTop: 12 }}><button type="submit" className="primary">Create item</button></p>
        </ActionForm>
      </div>
    </section>
  );
}
