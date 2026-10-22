import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { addRegistration, updateCompany, updateSettings } from "./actions";

export default async function CompanyPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: c }, { data: s }, { data: regs }] = await Promise.all([
    supabase.from("companies").select("*").eq("id", company.id).single(),
    supabase.from("company_settings").select("*").eq("company_id", company.id).single(),
    supabase.from("company_registrations").select("*").eq("company_id", company.id).order("registration_type"),
  ]);

  return (
    <section>
      <h1>Company</h1>
      <p className="muted">Code {c?.code} · base currency {c?.base_currency} · fiscal year starts month {c?.fiscal_year_start_month} (fixed at creation)</p>

      <div className="panel">
        <ActionForm action={updateCompany} resetOnSuccess={false}>
          <div className="form-grid">
            <label>Name<input name="name" defaultValue={c?.name} required /></label>
            <label>Legal name<input name="legal_name" defaultValue={c?.legal_name ?? ""} /></label>
            <label>Time zone<input name="timezone" defaultValue={c?.timezone} required /></label>
            <label>Phone<input name="phone" defaultValue={c?.phone ?? ""} /></label>
            <label>Email<input name="email" defaultValue={c?.email ?? ""} /></label>
            <label>Address<input name="address_line1" defaultValue={c?.address_line1 ?? ""} /></label>
            <label>Address 2<input name="address_line2" defaultValue={c?.address_line2 ?? ""} /></label>
            <label>City<input name="city" defaultValue={c?.city ?? ""} /></label>
            <label>Region<input name="region" defaultValue={c?.region ?? ""} /></label>
            <label>Postal code<input name="postal_code" defaultValue={c?.postal_code ?? ""} /></label>
          </div>
          <p style={{ marginTop: 10 }}><button type="submit" className="primary">Save company</button></p>
        </ActionForm>
      </div>

      <h2>Operating settings</h2>
      <div className="panel">
        <ActionForm action={updateSettings} resetOnSuccess={false}>
          <div className="form-row">
            <label className="narrow">Buffer yellow from %<input name="yellow_from_pct" type="number" min={1} max={99} defaultValue={s?.yellow_from_pct} required /></label>
            <label className="narrow">Buffer red from %<input name="red_from_pct" type="number" min={2} max={100} defaultValue={s?.red_from_pct} required /></label>
            <label className="narrow">Over-receipt tolerance %<input name="over_receipt_pct" type="number" step="any" min={0} defaultValue={s?.over_receipt_pct} /></label>
            <label className="check"><input type="checkbox" name="allow_negative_stock" defaultChecked={s?.allow_negative_stock} />Allow negative stock</label>
            <button type="submit" className="primary">Save settings</button>
          </div>
          <p className="muted small">Black = buffer penetration above 100%. Negative stock off means postings below zero need a superuser override with a reason.</p>
        </ActionForm>
      </div>

      <h2>Registrations</h2>
      <table className="grid" style={{ maxWidth: 640 }}>
        <tbody>
          {(regs ?? []).map((r: any) => <tr key={r.id}><td className="mono">{r.registration_type}</td><td className="mono">{r.registration_number}</td></tr>)}
          {(regs ?? []).length === 0 && <tr><td className="empty">None.</td></tr>}
        </tbody>
      </table>
      <ActionForm action={addRegistration}>
        <div className="form-row" style={{ marginTop: 8, maxWidth: 640 }}>
          <label className="narrow">Type<input name="registration_type" required placeholder="GSTIN" /></label>
          <label>Number<input name="registration_number" required /></label>
          <button type="submit">Add</button>
        </div>
      </ActionForm>
    </section>
  );
}
