import Link from "next/link";
import { requireCompany } from "@/lib/context";

type Search = Promise<{ q?: string; type?: string; inactive?: string }>;

export default async function PartnersPage({ searchParams }: { searchParams: Search }) {
  const { q, type, inactive } = await searchParams;
  const { supabase, company } = await requireCompany();

  let query = supabase
    .from("business_partners")
    .select("id, code, name, bp_type, currency_code, default_lead_time_days, phone, is_active")
    .eq("company_id", company.id)
    .order("code")
    .limit(500);
  if (q) {
    const s = q.replace(/[%,()]/g, "");
    query = query.or(`code.ilike.%${s}%,name.ilike.%${s}%`);
  }
  if (type) query = query.in("bp_type", [type, "BOTH"]);
  if (!inactive) query = query.eq("is_active", true);
  const { data, error } = await query;

  return (
    <section>
      <div className="page-head">
        <h1>Business partners</h1>
        <div className="spacer" />
        <Link href="/partners/new"><button className="primary">New partner</button></Link>
      </div>
      <form className="form-row panel" method="get">
        <label className="wide">Search code or name<input name="q" defaultValue={q ?? ""} /></label>
        <label>Type
          <select name="type" defaultValue={type ?? ""}>
            <option value="">All</option>
            <option value="SUPPLIER">Suppliers</option>
            <option value="CUSTOMER">Customers</option>
          </select>
        </label>
        <label className="check"><input type="checkbox" name="inactive" defaultChecked={!!inactive} />Include inactive</label>
        <button type="submit">Filter</button>
      </form>
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead><tr><th>Code</th><th>Name</th><th>Type</th><th>Currency</th><th className="num">Lead time</th><th>Phone</th><th></th></tr></thead>
        <tbody>
          {(data ?? []).map((b) => (
            <tr key={b.id}>
              <td className="mono"><Link href={`/partners/${b.id}`}>{b.code}</Link></td>
              <td>{b.name}</td>
              <td className="small">{b.bp_type}</td>
              <td className="mono">{b.currency_code ?? company.base_currency}</td>
              <td className="num">{b.default_lead_time_days != null ? `${b.default_lead_time_days} d` : ""}</td>
              <td className="small">{b.phone}</td>
              <td>{!b.is_active && <span className="badge off">inactive</span>}</td>
            </tr>
          ))}
          {(data ?? []).length === 0 && <tr><td colSpan={7} className="empty">No partners.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
