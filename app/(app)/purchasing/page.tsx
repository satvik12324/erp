import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { statusClass } from "@/lib/format";

type Search = Promise<{ status?: string; bp?: string }>;

export default async function PurchaseOrdersPage({ searchParams }: { searchParams: Search }) {
  const { status, bp } = await searchParams;
  const { supabase, company } = await requireCompany();
  const access = await getAccess();

  let q = supabase
    .from("purchase_orders")
    .select("id, doc_number, doc_date, required_date, status, currency_code, supplier_reference, business_partners(code, name), purchase_order_lines(count)")
    .eq("company_id", company.id)
    .order("doc_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(300);
  q = status ? q.eq("status", status) : q.in("status", ["DRAFT", "OPEN"]);
  if (bp) q = q.eq("business_partner_id", bp);
  const { data, error } = await q;

  return (
    <section>
      <div className="page-head">
        <div>
          <h1>Purchase orders</h1>
          <p className="muted">Draft and open orders by default.</p>
        </div>
        <div className="spacer" />
        <Link href="/purchasing/open">Open lines by due date</Link>
        {access.full("PURCHASING") && <Link href="/purchasing/new"><button className="primary">New purchase order</button></Link>}
      </div>
      <form className="form-row panel" method="get">
        <label>Status
          <select name="status" defaultValue={status ?? ""}>
            <option value="">Draft + open</option>
            <option value="DRAFT">Draft</option>
            <option value="OPEN">Open</option>
            <option value="CLOSED">Closed</option>
            <option value="CANCELLED">Cancelled</option>
          </select>
        </label>
        <button type="submit">Filter</button>
      </form>
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead>
          <tr><th>Number</th><th>Date</th><th>Supplier</th><th>Supplier ref.</th><th>Currency</th><th className="num">Lines</th><th>Required by</th><th>Status</th></tr>
        </thead>
        <tbody>
          {(data ?? []).map((p: any) => (
            <tr key={p.id}>
              <td className="mono"><Link href={`/purchasing/${p.id}`}>{p.doc_number ?? "(draft)"}</Link></td>
              <td>{p.doc_date}</td>
              <td><span className="mono">{p.business_partners?.code}</span> {p.business_partners?.name}</td>
              <td className="small">{p.supplier_reference}</td>
              <td className="mono">{p.currency_code}</td>
              <td className="num">{p.purchase_order_lines?.[0]?.count ?? 0}</td>
              <td>{p.required_date}</td>
              <td><span className={`badge ${statusClass(p.status)}`}>{p.status}</span></td>
            </tr>
          ))}
          {(data ?? []).length === 0 && <tr><td colSpan={8} className="empty">No purchase orders.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
