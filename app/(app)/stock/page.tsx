import Link from "next/link";
import { requireCompany } from "@/lib/context";

type Search = Promise<{ q?: string; wh?: string; neg?: string; zero?: string }>;
const fmt = (n: number | string) => Number(n).toLocaleString("en-IN", { maximumFractionDigits: 6 });

export default async function StockPage({ searchParams }: { searchParams: Search }) {
  const { q, wh, neg, zero } = await searchParams;
  const { supabase, company } = await requireCompany();

  let query = supabase
    .from("v_stock_on_hand")
    .select("item_id, item_code, item_name, warehouse_id, warehouse_code, on_hand, base_uom, last_movement_at")
    .eq("company_id", company.id)
    .order("item_code")
    .order("warehouse_code")
    .limit(2000);
  if (q) {
    const s = q.replace(/[%,()]/g, "");
    query = query.or(`item_code.ilike.%${s}%,item_name.ilike.%${s}%`);
  }
  if (wh) query = query.eq("warehouse_id", wh);
  if (neg) query = query.lt("on_hand", 0);
  else if (!zero) query = query.neq("on_hand", 0);

  const [{ data: rows, error }, { data: warehouses }, { data: onOrder }] = await Promise.all([
    query,
    supabase.from("warehouses").select("id, code, name").eq("company_id", company.id).order("code"),
    supabase.from("v_on_order").select("item_id, warehouse_id, on_order").eq("company_id", company.id),
  ]);
  const oo = new Map((onOrder ?? []).map((o: any) => [`${o.item_id}-${o.warehouse_id}`, Number(o.on_order)]));

  return (
    <section>
      <h1>Stock on hand</h1>
      <p className="muted">Quantities in each item&apos;s base unit, from posted documents.</p>
      <form className="form-row panel" method="get">
        <label className="wide">Item code or name<input name="q" defaultValue={q ?? ""} /></label>
        <label>Warehouse
          <select name="wh" defaultValue={wh ?? ""}>
            <option value="">All</option>
            {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name}</option>)}
          </select>
        </label>
        <label className="check"><input type="checkbox" name="neg" defaultChecked={!!neg} />Only below zero</label>
        <label className="check"><input type="checkbox" name="zero" defaultChecked={!!zero} />Show zero</label>
        <button type="submit">Filter</button>
      </form>
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead><tr><th>Item</th><th>Name</th><th>Warehouse</th><th className="num">On hand</th><th className="num">On order</th><th>Unit</th><th>Last movement</th></tr></thead>
        <tbody>
          {(rows ?? []).map((r: any) => (
            <tr key={`${r.item_id}-${r.warehouse_id}`}>
              <td className="mono"><Link href={`/items/${r.item_id}`}>{r.item_code}</Link></td>
              <td>{r.item_name}</td>
              <td className="mono">{r.warehouse_code}</td>
              <td className="num">{Number(r.on_hand) < 0 ? <span className="badge neg">{fmt(r.on_hand)}</span> : fmt(r.on_hand)}</td>
              <td className="num">{oo.get(`${r.item_id}-${r.warehouse_id}`) ? fmt(oo.get(`${r.item_id}-${r.warehouse_id}`)!) : ""}</td>
              <td className="mono">{r.base_uom}</td>
              <td className="small muted">{r.last_movement_at ? new Date(r.last_movement_at).toLocaleString("en-IN") : ""}</td>
            </tr>
          ))}
          {(rows ?? []).length === 0 && <tr><td colSpan={7} className="empty">No stock to show.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
