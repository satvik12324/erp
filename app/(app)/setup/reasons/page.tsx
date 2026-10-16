import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { createReason } from "./actions";

export default async function ReasonsPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: types }, { data: reasons }] = await Promise.all([
    supabase.from("reason_types").select("code, name").order("code"),
    supabase.from("reason_codes").select("id, reason_type, code, name, is_active").eq("company_id", company.id).order("reason_type").order("code"),
  ]);
  const typeName = new Map((types ?? []).map((t) => [t.code, t.name]));

  return (
    <section>
      <h1>Reason codes</h1>
      <p className="muted">Reasons recorded on cancellations, stock overrides, adjustments and buffer penetration (for Pareto analysis).</p>
      <table className="grid">
        <thead><tr><th>Group</th><th>Code</th><th>Name</th></tr></thead>
        <tbody>
          {(reasons ?? []).map((r) => (
            <tr key={r.id}><td>{typeName.get(r.reason_type)}</td><td className="mono">{r.code}</td><td>{r.name}</td></tr>
          ))}
          {(reasons ?? []).length === 0 && <tr><td colSpan={3} className="empty">No reasons yet.</td></tr>}
        </tbody>
      </table>
      <div className="panel" style={{ marginTop: 10 }}>
        <ActionForm action={createReason}>
          <div className="form-row">
            <label>Group
              <select name="reason_type" required>
                {(types ?? []).map((t) => <option key={t.code} value={t.code}>{t.name}</option>)}
              </select>
            </label>
            <label className="narrow">Code<input name="code" required maxLength={20} /></label>
            <label className="wide">Name<input name="name" required /></label>
            <button type="submit" className="primary">Add reason</button>
          </div>
        </ActionForm>
      </div>
    </section>
  );
}
