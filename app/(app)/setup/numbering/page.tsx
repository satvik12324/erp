import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { createDocType, createRange } from "./actions";

export default async function NumberingPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: ranges }, { data: types }, { data: cats }, { data: counters }] = await Promise.all([
    supabase.from("number_ranges").select("id, code, name, pattern, reset_policy, start_number, is_active").eq("company_id", company.id).order("code"),
    supabase.from("document_types").select("id, code, name, category, default_number_range_id, is_active").eq("company_id", company.id).order("code"),
    supabase.from("document_categories").select("code, name").order("sort_order"),
    supabase.from("number_range_counters").select("number_range_id, scope_key, period_key, next_number").eq("company_id", company.id),
  ]);
  const rangeCode = new Map((ranges ?? []).map((r) => [r.id, r.code]));
  const catName = new Map((cats ?? []).map((c) => [c.code, c.name]));

  return (
    <section>
      <h1>Numbering series &amp; document types</h1>
      <p className="muted">
        Series issue gapless numbers. Pattern tokens: <span className="mono">{"{N}"}</span> or <span className="mono">{"{N:5}"}</span> counter (required once),{" "}
        <span className="mono">{"{FY}"}</span> fiscal year (e.g. 26-27), <span className="mono">{"{YYYY}"}</span> calendar year,{" "}
        <span className="mono">{"{SCOPE}"}</span> scope (item group code when used for item codes).
      </p>

      <h2>Series</h2>
      <table className="grid">
        <thead><tr><th>Code</th><th>Name</th><th>Pattern</th><th>Reset</th><th>Counters (scope · period → next)</th></tr></thead>
        <tbody>
          {(ranges ?? []).map((r) => (
            <tr key={r.id}>
              <td className="mono">{r.code}</td><td>{r.name}</td><td className="mono">{r.pattern}</td><td>{r.reset_policy}</td>
              <td className="small">
                {(counters ?? []).filter((c) => c.number_range_id === r.id)
                  .map((c) => `${c.scope_key || "–"} · ${c.period_key || "–"} → ${c.next_number}`).join(";  ") || <span className="muted">not used yet</span>}
              </td>
            </tr>
          ))}
          {(ranges ?? []).length === 0 && <tr><td colSpan={5} className="empty">No series yet.</td></tr>}
        </tbody>
      </table>
      <div className="panel" style={{ marginTop: 10 }}>
        <ActionForm action={createRange}>
          <div className="form-row">
            <label className="narrow">Code<input name="code" required maxLength={20} placeholder="ITEM" /></label>
            <label>Name<input name="name" required /></label>
            <label>Pattern<input name="pattern" required placeholder="{SCOPE}-{N:4}" className="mono" /></label>
            <label className="narrow">Reset
              <select name="reset_policy" defaultValue="NONE">
                <option value="NONE">Never</option>
                <option value="FISCAL_YEAR">Fiscal year</option>
                <option value="CALENDAR_YEAR">Calendar year</option>
              </select>
            </label>
            <label className="narrow">Start at<input name="start_number" type="number" min={0} defaultValue={1} /></label>
            <button type="submit" className="primary">Add series</button>
          </div>
        </ActionForm>
      </div>

      <h2>Document types</h2>
      <table className="grid">
        <thead><tr><th>Code</th><th>Name</th><th>Behaves as</th><th>Series</th></tr></thead>
        <tbody>
          {(types ?? []).map((t) => (
            <tr key={t.id}>
              <td className="mono">{t.code}</td><td>{t.name}</td><td>{catName.get(t.category)}</td>
              <td className="mono">{t.default_number_range_id ? rangeCode.get(t.default_number_range_id) : "—"}</td>
            </tr>
          ))}
          {(types ?? []).length === 0 && <tr><td colSpan={4} className="empty">No document types yet.</td></tr>}
        </tbody>
      </table>
      <div className="panel" style={{ marginTop: 10 }}>
        <ActionForm action={createDocType}>
          <div className="form-row">
            <label className="narrow">Code<input name="code" required maxLength={20} /></label>
            <label className="wide">Name<input name="name" required /></label>
            <label>Behaves as
              <select name="category" required>
                {(cats ?? []).map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
              </select>
            </label>
            <label>Series
              <select name="default_number_range_id" required>
                {(ranges ?? []).map((r) => <option key={r.id} value={r.id}>{r.code} · {r.pattern}</option>)}
              </select>
            </label>
            <button type="submit" className="primary">Add type</button>
          </div>
        </ActionForm>
      </div>
    </section>
  );
}
