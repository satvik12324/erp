import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { addConversion, createUom, createUomGroup, deleteConversion } from "./actions";

export default async function UomsPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: uoms }, { data: groups }] = await Promise.all([
    supabase.from("uoms").select("id, code, name, decimals").eq("company_id", company.id).order("code"),
    supabase
      .from("uom_groups")
      .select("id, code, name, base_uom_id, uom_group_conversions(id, alt_uom_id, alt_qty, base_qty)")
      .eq("company_id", company.id)
      .order("code"),
  ]);
  const code = new Map((uoms ?? []).map((u) => [u.id, u.code]));

  return (
    <section>
      <h1>Units of measure</h1>
      <p className="muted">
        Units, and UoM groups that say which units an item can be bought, stocked and sold in. Stock is kept in the group&apos;s base unit.
      </p>

      <h2>Units</h2>
      <table className="grid">
        <thead><tr><th>Code</th><th>Name</th><th className="num">Decimals</th></tr></thead>
        <tbody>
          {(uoms ?? []).map((u) => (
            <tr key={u.id}><td className="mono">{u.code}</td><td>{u.name}</td><td className="num">{u.decimals}</td></tr>
          ))}
          {(uoms ?? []).length === 0 && <tr><td colSpan={3} className="empty">No units yet.</td></tr>}
        </tbody>
      </table>
      <div className="panel" style={{ marginTop: 10 }}>
        <ActionForm action={createUom}>
          <div className="form-row">
            <label className="narrow">Code<input name="code" required maxLength={20} placeholder="PCS" /></label>
            <label className="wide">Name<input name="name" required placeholder="Pieces" /></label>
            <label className="narrow">Decimals<input name="decimals" type="number" min={0} max={6} defaultValue={0} /></label>
            <button type="submit" className="primary">Add unit</button>
          </div>
        </ActionForm>
      </div>

      <h2>UoM groups</h2>
      {(groups ?? []).map((g: any) => (
        <div className="panel" key={g.id}>
          <strong className="mono">{g.code}</strong> · {g.name} <span className="muted">· base unit {code.get(g.base_uom_id)}</span>
          <table className="grid" style={{ marginTop: 8 }}>
            <thead><tr><th>Unit</th><th>Conversion</th><th></th></tr></thead>
            <tbody>
              {g.uom_group_conversions.map((c: any) => (
                <tr key={c.id}>
                  <td className="mono">{code.get(c.alt_uom_id)}</td>
                  <td>{Number(c.alt_qty)} {code.get(c.alt_uom_id)} = {Number(c.base_qty)} {code.get(g.base_uom_id)}</td>
                  <td className="num">
                    {c.alt_uom_id !== g.base_uom_id && (
                      <ActionForm action={deleteConversion} confirm="Remove this conversion?">
                        <input type="hidden" name="id" value={c.id} />
                        <button type="submit" className="link">Remove</button>
                      </ActionForm>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <ActionForm action={addConversion}>
            <input type="hidden" name="uom_group_id" value={g.id} />
            <div className="form-row" style={{ marginTop: 8 }}>
              <label className="narrow">Alt. qty<input name="alt_qty" type="number" step="any" min={0} defaultValue={1} required /></label>
              <label>Unit
                <select name="alt_uom_id" required>
                  {(uoms ?? []).map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                </select>
              </label>
              <span style={{ alignSelf: "center" }}>=</span>
              <label className="narrow">Base qty<input name="base_qty" type="number" step="any" min={0} required /></label>
              <span style={{ alignSelf: "center" }} className="mono">{code.get(g.base_uom_id)}</span>
              <button type="submit">Add conversion</button>
            </div>
          </ActionForm>
        </div>
      ))}

      <div className="panel">
        <strong>New UoM group</strong>
        <ActionForm action={createUomGroup}>
          <div className="form-row" style={{ marginTop: 8 }}>
            <label className="narrow">Code<input name="code" required maxLength={20} placeholder="PCS-BOX" /></label>
            <label className="wide">Name<input name="name" required placeholder="Pieces / boxes" /></label>
            <label>Base unit
              <select name="base_uom_id" required>
                {(uoms ?? []).map((u) => <option key={u.id} value={u.id}>{u.code} · {u.name}</option>)}
              </select>
            </label>
            <button type="submit" className="primary">Create group</button>
          </div>
        </ActionForm>
      </div>
    </section>
  );
}
