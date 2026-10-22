import { requireCompany } from "@/lib/context";
import { fmt } from "@/lib/format";
import { ActionForm } from "@/components/ActionForm";
import { saveRate } from "./actions";

export default async function ExchangeRatesPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: rates }, { data: currencies }] = await Promise.all([
    supabase.from("exchange_rates").select("id, currency_code, rate_date, rate").eq("company_id", company.id)
      .order("rate_date", { ascending: false }).order("currency_code").limit(200),
    supabase.from("currencies").select("code, name").eq("is_active", true).neq("code", company.base_currency).order("code"),
  ]);
  const today = new Date().toISOString().slice(0, 10);

  return (
    <section>
      <h1>Exchange rates</h1>
      <p className="muted">
        1 unit of the foreign currency = rate × {company.base_currency}. A foreign-currency document needs a rate for its exact date
        (as in SAP Business One).
      </p>
      <div className="panel">
        <ActionForm action={saveRate}>
          <div className="form-row">
            <label className="narrow">Currency
              <select name="currency_code" required>
                {(currencies ?? []).map((c) => <option key={c.code} value={c.code}>{c.code} · {c.name}</option>)}
              </select>
            </label>
            <label className="narrow">Date<input name="rate_date" type="date" defaultValue={today} required /></label>
            <label className="narrow">Rate ({company.base_currency})<input name="rate" type="number" step="any" min={0} required /></label>
            <button type="submit" className="primary">Save rate</button>
          </div>
        </ActionForm>
      </div>
      <table className="grid" style={{ maxWidth: 560 }}>
        <thead><tr><th>Date</th><th>Currency</th><th className="num">Rate</th></tr></thead>
        <tbody>
          {(rates ?? []).map((r) => (
            <tr key={r.id}><td>{r.rate_date}</td><td className="mono">{r.currency_code}</td><td className="num">{fmt(r.rate, 6)} {company.base_currency}</td></tr>
          ))}
          {(rates ?? []).length === 0 && <tr><td colSpan={3} className="empty">No rates yet.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
