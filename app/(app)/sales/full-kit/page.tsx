import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { fmt } from "@/lib/format";
import { Meter, Zone } from "@/components/Zone";

// Full-kit work queue (D-046). Everything comes from one allocation of on-hand stock to open orders in buffer-priority
// order, so the three lists never promise the same stock twice:
//   ready to ship   kit complete from finished stock
//   build next      what to make, per order, in priority order (components are on hand)
//   shortages       what blocks the remaining orders, per item, most urgent order first
export default async function FullKitPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: orders, error }, { data: reqs }] = await Promise.all([
    supabase.from("v_sales_order_buffer").select("*").eq("company_id", company.id),
    supabase.from("v_full_kit_lines").select("*").eq("company_id", company.id).neq("requirement_status", "COVERED"),
  ]);

  const byRank = (a: any, b: any) => (a.priority_rank ?? 1e9) - (b.priority_rank ?? 1e9);
  const ready = (orders ?? []).filter((o: any) => o.kit_status === "READY" && o.open_lines > 0).sort(byRank);
  const buildable = (orders ?? []).filter((o: any) => o.kit_status === "BUILDABLE").sort(byRank);
  const orderById = new Map((orders ?? []).map((o: any) => [o.sales_order_id, o]));

  // what to build per order: short quantities of MAKE items whose components are on hand
  const builds = new Map<string, any[]>();
  for (const r of reqs ?? []) {
    if (r.requirement_status !== "BUILD") continue;
    if (!builds.has(r.sales_order_id)) builds.set(r.sales_order_id, []);
    builds.get(r.sales_order_id)!.push(r);
  }

  // shortages per item + warehouse
  const short = new Map<string, any>();
  for (const r of reqs ?? []) {
    if (r.requirement_status !== "SHORT") continue;
    const key = `${r.item_id}-${r.warehouse_id}`;
    const s = short.get(key) ?? { ...r, total_short: 0, orders: new Set<string>(), first_rank: r.priority_rank, first_order: r.sales_order_id };
    s.total_short += Number(r.short_qty);
    s.orders.add(r.sales_order_id);
    if (r.priority_rank < s.first_rank) { s.first_rank = r.priority_rank; s.first_order = r.sales_order_id; }
    short.set(key, s);
  }
  const shortages = [...short.values()].sort((a, b) => a.first_rank - b.first_rank);

  return (
    <section>
      <div className="page-head">
        <div>
          <h1>Full kit</h1>
          <p className="muted">
            Stock on hand allocated to open orders in priority order (most penetrated buffer first). Work top-down; do not
            start an order further down while one above it can be done.
          </p>
        </div>
        <div className="spacer" />
        <Link href="/sales/board">Order board</Link>
      </div>
      {error && <p className="msg err">{error.message}</p>}

      <h2>Ready to ship <span className="muted small">({ready.length})</span></h2>
      <table className="grid">
        <thead><tr><th className="num">#</th><th>Zone</th><th>Order</th><th>Customer</th><th>Due</th><th className="num">Open lines</th></tr></thead>
        <tbody>
          {ready.map((o: any) => (
            <tr key={o.sales_order_id} className={`row-${o.zone}`}>
              <td className="num">{o.priority_rank}</td>
              <td><Zone zone={o.zone} /> <Meter pct={o.penetration} zone={o.zone} /></td>
              <td className="mono"><Link href={`/sales/${o.sales_order_id}`}>{o.doc_number}</Link></td>
              <td><span className="mono">{o.customer_code}</span> {o.customer_name}</td>
              <td>{o.due_date}</td>
              <td className="num">{o.open_lines}</td>
            </tr>
          ))}
          {ready.length === 0 && <tr><td colSpan={6} className="empty">No order is complete from finished stock.</td></tr>}
        </tbody>
      </table>

      <h2>Build next <span className="muted small">({buildable.length})</span></h2>
      <p className="muted small">
        Components are on hand for these orders. Make the quantities shown (lowest level first), then post a receipt from
        production for each item.
      </p>
      <table className="grid">
        <thead><tr><th className="num">#</th><th>Zone</th><th>Order</th><th>Customer</th><th>Due</th><th>To make</th></tr></thead>
        <tbody>
          {buildable.map((o: any) => (
            <tr key={o.sales_order_id} className={`row-${o.zone}`}>
              <td className="num">{o.priority_rank}</td>
              <td><Zone zone={o.zone} /> <Meter pct={o.penetration} zone={o.zone} /></td>
              <td className="mono"><Link href={`/sales/${o.sales_order_id}#kit`}>{o.doc_number}</Link></td>
              <td><span className="mono">{o.customer_code}</span> {o.customer_name}</td>
              <td>{o.due_date}</td>
              <td>
                {(builds.get(o.sales_order_id) ?? [])
                  .sort((a: any, b: any) => b.level - a.level || a.seq - b.seq)
                  .map((b: any) => (
                    <div key={b.seq} className="small">
                      <Link href={`/items/${b.item_id}`} className="mono">{b.item_code}</Link> {fmt(b.short_qty, 3)} {b.base_uom}
                      <span className="muted"> · {b.warehouse_code}</span>
                    </div>
                  ))}
              </td>
            </tr>
          ))}
          {buildable.length === 0 && <tr><td colSpan={6} className="empty">Nothing to build from components on hand.</td></tr>}
        </tbody>
      </table>

      <h2>Shortages <span className="muted small">({shortages.length})</span></h2>
      <p className="muted small">
        Items missing for orders that cannot be completed now, most urgent order first. Bought items need a purchase
        order (see Replenishment); a made item listed here has no active BOM.
      </p>
      <table className="grid">
        <thead>
          <tr>
            <th>Item</th><th>Warehouse</th><th className="num">Short</th><th className="num">Orders</th><th>Most urgent order</th>
            <th className="num">On order</th><th>Next receipt</th>
          </tr>
        </thead>
        <tbody>
          {shortages.map((s: any) => {
            const o: any = orderById.get(s.first_order);
            return (
              <tr key={`${s.item_id}-${s.warehouse_id}`} className={o ? `row-${o.zone}` : ""}>
                <td><Link href={`/items/${s.item_id}`} className="mono">{s.item_code}</Link> <span className="small">{s.item_name}</span></td>
                <td className="mono">{s.warehouse_code}</td>
                <td className="num">{fmt(s.total_short, 3)} <span className="small">{s.base_uom}</span></td>
                <td className="num">{s.orders.size}</td>
                <td>{o && <><Zone zone={o.zone} /> <Link href={`/sales/${o.sales_order_id}#kit`} className="mono">{o.doc_number}</Link> <span className="small">#{o.priority_rank}</span></>}</td>
                <td className="num">{Number(s.on_order) > 0 ? fmt(s.on_order, 3) : ""}</td>
                <td>{s.next_expected_date ?? <span className="badge neg">nothing on order</span>}</td>
              </tr>
            );
          })}
          {shortages.length === 0 && <tr><td colSpan={7} className="empty">No shortages.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
