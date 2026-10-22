import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { Meter, Zone, ZoneCounts, ZONE_ORDER } from "@/components/Zone";
import { KitBadge } from "@/components/Kit";

// Open sales orders in TOC priority: buffer zone first (black, red, yellow, green), then penetration.
// Due date and order of arrival do not set priority (Rule 4).
const KITS = ["READY", "BUILDABLE", "SHORT"];

export default async function OrderBoardPage({ searchParams }: { searchParams: Promise<{ kit?: string }> }) {
  const { kit } = await searchParams;
  const { supabase, company } = await requireCompany();
  await supabase.rpc("take_buffer_snapshot", { p_company_id: company.id }); // keeps today's history and events current
  const [{ data, error }, { data: events }] = await Promise.all([
    supabase.from("v_sales_order_buffer").select("*").eq("company_id", company.id),
    supabase.from("buffer_events").select("sales_order_id").eq("company_id", company.id).eq("buffer_kind", "ORDER").is("reason_code_id", null),
  ]);
  const all = [...(data ?? [])];
  const rows = all.filter((r: any) => !kit || r.kit_status === kit).sort(
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
        <Link href="/sales/full-kit">Full kit</Link>
        <span className="muted">·</span>
        <Link href="/buffers/reasons">Red/black reasons</Link>
      </div>
      <p className="small">
        Kit:{" "}
        <Link href="/sales/board" className={kit ? "" : "strong"}>all ({all.length})</Link>
        {KITS.map((k) => (
          <span key={k}> · <Link href={`/sales/board?kit=${k}`} className={kit === k ? "strong" : ""}>{k.toLowerCase()} ({all.filter((r: any) => r.kit_status === k).length})</Link></span>
        ))}
      </p>
      <ZoneCounts zones={rows.map((r: any) => r.zone)} />
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead>
          <tr><th>Zone</th><th>Penetration</th><th>Order</th><th>Customer</th><th>Customer ref.</th><th>Due</th><th className="num">Days left</th><th className="num">Open lines</th><th>Kit</th><th className="num">Priority</th><th></th></tr>
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
              <td><Link href={`/sales/${r.sales_order_id}#kit`}><KitBadge status={r.kit_status} /></Link></td>
              <td className="num">{r.priority_rank ?? ""}</td>
              <td>{needsReason.has(r.sales_order_id) && <Link href="/buffers/reasons" className="badge DRAFT">reason needed</Link>}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={11} className="empty">No open sales orders{kit ? " with this kit status" : ""}.</td></tr>}
        </tbody>
      </table>
      <p className="muted small">
        Penetration = days elapsed since the buffer started ÷ buffer length. Buffer starts at due date − time buffer days.
        Kit: stock on hand is allocated to orders in priority order (most penetrated first); finished units that are
        short are exploded through their BOM, any number of levels. Ready = all lines on hand, buildable = the rest
        can be made from components on hand now, short = something is missing.
      </p>
    </section>
  );
}
