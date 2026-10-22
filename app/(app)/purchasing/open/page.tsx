import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { fmt } from "@/lib/format";

type Search = Promise<{ bp?: string; late?: string }>;

// Open PO lines by expected date: what is coming, from whom, and what is overdue.
export default async function OpenPoLinesPage({ searchParams }: { searchParams: Search }) {
  const { bp, late } = await searchParams;
  const { supabase, company } = await requireCompany();

  let q = supabase
    .from("v_open_po_lines")
    .select("*")
    .eq("company_id", company.id)
    .order("expected_date", { ascending: true, nullsFirst: false })
    .order("doc_number")
    .limit(1000);
  if (bp) q = q.eq("business_partner_id", bp);
  if (late) q = q.gt("days_overdue", 0);
  const [{ data: rows, error }, { data: suppliers }] = await Promise.all([
    q,
    supabase.from("business_partners").select("id, code, name").eq("company_id", company.id).in("bp_type", ["SUPPLIER", "BOTH"]).order("code"),
  ]);

  return (
    <section>
      <h1>Open purchase order lines</h1>
      <p className="muted">Everything still to be received, earliest promise first. Quantities in base units.</p>
      <form className="form-row panel" method="get">
        <label>Supplier
          <select name="bp" defaultValue={bp ?? ""}>
            <option value="">All</option>
            {(suppliers ?? []).map((s) => <option key={s.id} value={s.id}>{s.code} · {s.name}</option>)}
          </select>
        </label>
        <label className="check"><input type="checkbox" name="late" defaultChecked={!!late} />Only overdue</label>
        <button type="submit">Filter</button>
      </form>
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead>
          <tr><th>Expected</th><th>PO</th><th>Supplier</th><th>Item</th><th>Warehouse</th><th className="num">Open</th><th>Required</th><th className="num">Overdue</th></tr>
        </thead>
        <tbody>
          {(rows ?? []).map((r: any) => (
            <tr key={r.purchase_order_line_id}>
              <td>{r.expected_date ?? <span className="muted">—</span>}</td>
              <td className="mono"><Link href={`/purchasing/${r.purchase_order_id}`}>{r.doc_number}</Link> <span className="muted small">/{r.line_no}</span></td>
              <td><span className="mono">{r.supplier_code}</span> <span className="small">{r.supplier_name}</span></td>
              <td><Link href={`/items/${r.item_id}`} className="mono">{r.item_code}</Link> <span className="small">{r.item_name}</span></td>
              <td className="mono">{r.warehouse_code}</td>
              <td className="num">{fmt(r.open_qty_base)} <span className="mono small">{r.base_uom}</span></td>
              <td>{r.required_date}</td>
              <td className="num">{r.days_overdue > 0 ? <span className="badge neg">{r.days_overdue} d</span> : ""}</td>
            </tr>
          ))}
          {(rows ?? []).length === 0 && <tr><td colSpan={8} className="empty">Nothing open.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
