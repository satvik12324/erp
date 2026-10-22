import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { Meter, Zone, ZoneCounts, ZONE_ORDER } from "@/components/Zone";

// Open sales orders in TOC priority: buffer zone first (black, red, yellow, green), then penetration.
// Due date and order of arrival do not set priority (Rule 4).
export default async function OrderBoardPage() {
  const { supabase, company } = await requireCompany();
  await supabase.rpc("take_buffer_snapshot", { p_company_id: company.id }); // keeps today's history and events current
  const [{ data, error }, { data: events }] = await Promise.all([
    supabase.from("v_sales_order_buffer").select("*").eq("company_id", company.id),
    supabase.from("buffer_events").select("sales_order_id").eq("company_id", company.id).eq("buffer_kind", "ORDER").is("reason_code_id", null),
  ]);
  const rows = [...(data ?? [])].sort(
    (a: any, b: any) => ZONE_ORDER[a.zone] - ZONE_ORDER[b.zone] || Number(b.penetration) - Number(a.penetration) || (a.due_date < b.due_date ? -1 : 1),
  );
  const needsReason = new Set((events ?? []).map((e: any) => e.sales_order_id));

  return (
    <section>
      <div className="page-head">
        <div>
          <h1>Order board</h1>
          <p className="muted">Open sales orders by buffer status. Work from the top: black and red first, regardless of due date.</p>
        </div>
        <div className="spacer" />
        <Link href="/buffers/reasons">Red/black reasons</Link>
      </div>
      <ZoneCounts zones={rows.map((r: any) => r.zone)} />
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead>
          <tr><th>Zone</th><th>Penetration</th><th>Order</th><th>Customer</th><th>Customer ref.</th><th>Due</th><th className="num">Days left</th><th className="num">Open lines</th><th>Stock</th><th></th></tr>
        </thead>
        <tbody>
          {rows.map((r: any) => (
            <tr key={r.sales_order_id} className={`row-${r.zone}`}>
              <td><Zone zone={r.zone} /></td>
              <td><Meter pct={r.penetration} zone={r.zone} /></td>
              <td className="mono"><Link href={`/sales/${r.sales_order_id}`}>{r.doc_number}</Link></td>
              <td><span className="mono">{r.customer_code}</span> {r.customer_name}</td>
              <td className="small">{r.customer_reference}</td>
              <td>{r.due_date}</td>
              <td className="num">{r.days_to_due}</td>
              <td className="num">{r.open_lines}</td>
              <td>{r.stock_covered ? <span className="badge POSTED">on hand</span> : <span className="badge neg">short</span>}</td>
              <td>{needsReason.has(r.sales_order_id) && <Link href="/buffers/reasons" className="badge DRAFT">reason needed</Link>}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={10} className="empty">No open sales orders.</td></tr>}
        </tbody>
      </table>
      <p className="muted small">
        Penetration = days elapsed since the buffer started ÷ buffer length. Buffer starts at due date − time buffer days.
        &quot;Stock&quot; checks each open line against on hand in its warehouse, before other orders.
      </p>
    </section>
  );
}
