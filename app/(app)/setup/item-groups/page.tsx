import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { createItemGroup, updateItemGroup } from "./actions";

type Opt = { id: string; code: string; name?: string; pattern?: string };

function GroupFields({ g, ranges, uomGroups }: { g?: any; ranges: Opt[]; uomGroups: Opt[] }) {
  return (
    <>
      <label className="wide">Name<input name="name" defaultValue={g?.name} required /></label>
      <label>Item code series
        <select name="number_range_id" defaultValue={g?.number_range_id ?? ""}>
          <option value="">— enter codes by hand —</option>
          {ranges.map((r) => <option key={r.id} value={r.id}>{r.code} · {r.pattern}</option>)}
        </select>
      </label>
      <label>Default UoM group
        <select name="default_uom_group_id" defaultValue={g?.default_uom_group_id ?? ""}>
          <option value="">—</option>
          {uomGroups.map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
        </select>
      </label>
      <label className="narrow">Type
        <select name="default_item_type" defaultValue={g?.default_item_type ?? "INVENTORY"}>
          <option value="INVENTORY">Inventory</option>
          <option value="NON_INVENTORY">Non-inventory</option>
          <option value="SERVICE">Service</option>
        </select>
      </label>
      <label className="narrow">Procurement
        <select name="default_procurement_method" defaultValue={g?.default_procurement_method ?? "BUY"}>
          <option value="BUY">Buy</option>
          <option value="MAKE">Make</option>
        </select>
      </label>
      <label className="narrow">Replenishment
        <select name="default_replenishment_policy" defaultValue={g?.default_replenishment_policy ?? "TO_ORDER"}>
          <option value="BUFFER">Buffer (to stock)</option>
          <option value="TO_ORDER">To order</option>
        </select>
      </label>
    </>
  );
}

export default async function ItemGroupsPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: groups }, { data: ranges }, { data: uomGroups }] = await Promise.all([
    supabase.from("item_groups").select("*").eq("company_id", company.id).order("code"),
    supabase.from("number_ranges").select("id, code, pattern").eq("company_id", company.id).order("code"),
    supabase.from("uom_groups").select("id, code").eq("company_id", company.id).order("code"),
  ]);

  return (
    <section>
      <h1>Item groups</h1>
      <p className="muted">
        Groups give new items their defaults and, with a series like <span className="mono">{"{SCOPE}-{N:4}"}</span>, generate item codes per group
        (FRM-0001, FRK-0001 …).
      </p>
      {(groups ?? []).map((g) => (
        <div className="panel" key={g.id}>
          <ActionForm action={updateItemGroup} resetOnSuccess={false}>
            <input type="hidden" name="id" value={g.id} />
            <div className="form-row">
              <label className="narrow">Code<input value={g.code} readOnly className="mono" /></label>
              <GroupFields g={g} ranges={ranges ?? []} uomGroups={uomGroups ?? []} />
              <button type="submit">Save</button>
            </div>
          </ActionForm>
        </div>
      ))}
      {(groups ?? []).length === 0 && <p className="empty">No item groups yet.</p>}

      <h2>New item group</h2>
      <div className="panel">
        <ActionForm action={createItemGroup}>
          <div className="form-row">
            <label className="narrow">Code<input name="code" required maxLength={20} placeholder="FRM" /></label>
            <GroupFields ranges={ranges ?? []} uomGroups={uomGroups ?? []} />
            <button type="submit" className="primary">Create</button>
          </div>
        </ActionForm>
      </div>
    </section>
  );
}
