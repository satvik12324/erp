import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { createWarehouse, updateWarehouse } from "./actions";

export default async function WarehousesPage() {
  const { supabase, company } = await requireCompany();
  const { data } = await supabase
    .from("warehouses")
    .select("id, code, name, address, is_default, is_active")
    .eq("company_id", company.id)
    .order("code");

  return (
    <section>
      <div className="page-head">
        <div>
          <h1>Warehouses</h1>
          <p className="muted">Stock locations. The main warehouse is used when an item or BOM line names none.</p>
        </div>
      </div>

      <table className="grid">
        <thead>
          <tr><th>Code</th><th>Name</th><th>Address</th><th>Main</th><th>Active</th><th></th></tr>
        </thead>
        <tbody>
          {(data ?? []).map((w) => (
            <tr key={w.id}>
              <td className="mono">{w.code}</td>
              <td colSpan={5}>
                <ActionForm action={updateWarehouse} resetOnSuccess={false}>
                  <input type="hidden" name="id" value={w.id} />
                  <div className="form-row">
                    <label className="wide">Name<input name="name" defaultValue={w.name} required /></label>
                    <label className="wide">Address<input name="address" defaultValue={w.address ?? ""} /></label>
                    <label className="check"><input type="checkbox" name="is_default" defaultChecked={w.is_default} disabled={w.is_default} />Main</label>
                    {w.is_default && <input type="hidden" name="is_default" value="on" />}
                    <label className="check"><input type="checkbox" name="is_active" defaultChecked={w.is_active} />Active</label>
                    <button type="submit">Save</button>
                  </div>
                </ActionForm>
              </td>
            </tr>
          ))}
          {(data ?? []).length === 0 && <tr><td colSpan={6} className="empty">No warehouses yet.</td></tr>}
        </tbody>
      </table>

      <h2>New warehouse</h2>
      <div className="panel">
        <ActionForm action={createWarehouse}>
          <div className="form-row">
            <label className="narrow">Code<input name="code" required maxLength={20} placeholder="WH3" /></label>
            <label className="wide">Name<input name="name" required /></label>
            <label className="wide">Address<input name="address" /></label>
            <label className="check"><input type="checkbox" name="is_default" />Main warehouse</label>
            <button type="submit" className="primary">Create</button>
          </div>
        </ActionForm>
      </div>
    </section>
  );
}
