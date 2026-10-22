import Link from "next/link";
import { requireCompany } from "@/lib/context";

// Planned vs actual supplier lead times, measured from every receipt against a PO.
export default async function LeadTimesPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: stats, error }, { data: items }, { data: bps }] = await Promise.all([
    supabase.from("v_item_supplier_lead_time").select("*").eq("company_id", company.id).order("receipts", { ascending: false }),
    supabase.from("items").select("id, item_code, name").eq("company_id", company.id),
    supabase.from("business_partners").select("id, code, name").eq("company_id", company.id),
  ]);
  const item = new Map((items ?? []).map((i) => [i.id, i]));
  const bp = new Map((bps ?? []).map((b) => [b.id, b]));

  return (
    <section>
      <h1>Supplier lead times</h1>
      <p className="muted">
        Actual = receipt date − PO date, per item and supplier. Use the 80th percentile when sizing buffers; a large gap to
        the planned value means the planned lead time is wrong.
      </p>
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead>
          <tr>
            <th>Item</th><th>Supplier</th><th className="num">Receipts</th><th className="num">Planned</th><th className="num">Average</th>
            <th className="num">80th pct</th><th className="num">Max</th><th className="num">On time</th><th>Last received</th>
          </tr>
        </thead>
        <tbody>
          {(stats ?? []).map((s: any) => {
            const i: any = item.get(s.item_id);
            const b: any = bp.get(s.business_partner_id);
            const gap = s.planned_days != null && Number(s.p80_days) > s.planned_days * 1.25;
            return (
              <tr key={`${s.item_id}-${s.business_partner_id}`}>
                <td><Link href={`/items/${s.item_id}`} className="mono">{i?.item_code}</Link> <span className="small">{i?.name}</span></td>
                <td><Link href={`/partners/${s.business_partner_id}`} className="mono">{b?.code}</Link> <span className="small">{b?.name}</span></td>
                <td className="num">{s.receipts}</td>
                <td className="num">{s.planned_days != null ? `${s.planned_days} d` : "–"}</td>
                <td className="num">{s.avg_days} d</td>
                <td className="num">{gap ? <span className="badge neg">{Number(s.p80_days)} d</span> : `${Number(s.p80_days)} d`}</td>
                <td className="num">{s.max_days} d</td>
                <td className="num">{s.on_time_pct != null ? `${s.on_time_pct}%` : "–"}</td>
                <td>{s.last_received_on}</td>
              </tr>
            );
          })}
          {(stats ?? []).length === 0 && <tr><td colSpan={9} className="empty">No receipts against purchase orders yet.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
