import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { statusClass } from "@/lib/format";
import { Zone } from "@/components/Zone";

type Search = Promise<{ status?: string }>;

export default async function SalesOrdersPage({ searchParams }: { searchParams: Search }) {
  const { status } = await searchParams;
  const { supabase, company } = await requireCompany();
  const access = await getAccess();

  let q = supabase
    .from("sales_orders")
    .select("id, doc_number, doc_date, due_date, time_buffer_days, status, close_type, currency_code, customer_reference, business_partners(code, name), sales_order_lines(count)")
    .eq("company_id", company.id)
    .order("doc_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(300);
  q = status ? q.eq("status", status) : q.in("status", ["DRAFT", "OPEN"]);
  const [{ data, error }, { data: buffers }] = await Promise.all([
    q,
    supabase.from("v_sales_order_buffer").select("sales_order_id, penetration, zone").eq("company_id", company.id),
  ]);
  const zone = new Map((buffers ?? []).map((b: any) => [b.sales_order_id, b]));

  return (
    <section>
      <div className="page-head">
        <div>
          <h1>Sales orders</h1>
          <p className="muted">Draft and open orders by default. Work open orders from the <Link href="/sales/board">order board</Link>, which sorts by buffer status.</p>
        </div>
        <div className="spacer" />
        {access.full("SALES") && <Link href="/sales/new"><button className="primary">New sales order</button></Link>}
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
          <tr><th>Number</th><th>Date</th><th>Customer</th><th>Customer ref.</th><th className="num">Lines</th><th>Due</th><th>Buffer</th><th>Status</th></tr>
        </thead>
        <tbody>
          {(data ?? []).map((o: any) => {
            const b: any = zone.get(o.id);
            return (
              <tr key={o.id}>
                <td className="mono"><Link href={`/sales/${o.id}`}>{o.doc_number ?? "(draft)"}</Link></td>
                <td>{o.doc_date}</td>
                <td><span className="mono">{o.business_partners?.code}</span> {o.business_partners?.name}</td>
                <td className="small">{o.customer_reference}</td>
                <td className="num">{o.sales_order_lines?.[0]?.count ?? 0}</td>
                <td>{o.due_date}</td>
                <td>{b && <><Zone zone={b.zone} /> <span className="small">{b.penetration}%</span></>}</td>
                <td><span className={`badge ${statusClass(o.status)}`}>{o.status}{o.close_type === "MANUAL" ? " · short" : ""}</span></td>
              </tr>
            );
          })}
          {(data ?? []).length === 0 && <tr><td colSpan={8} className="empty">No sales orders.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
