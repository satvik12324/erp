import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { fmt } from "@/lib/format";
import { ActionForm } from "@/components/ActionForm";
import { Zone, ZONE_ORDER } from "@/components/Zone";
import { createPurchaseOrders } from "./actions";

// Daily replenishment proposal: buffers below target (replenish to target) and to-order shortages,
// most urgent first. The user selects lines and converts them into draft purchase orders.
export default async function ReplenishmentPage() {
  const { supabase, company } = await requireCompany();
  const access = await getAccess();
  const [{ data, error }, { data: poTypes }] = await Promise.all([
    supabase.from("v_replenishment").select("*").eq("company_id", company.id),
    supabase.from("document_types").select("id, name").eq("company_id", company.id).eq("category", "PURCHASE_ORDER").eq("is_active", true).order("code"),
  ]);
  const rank = (r: any) => (r.source === "BUFFER" ? ZONE_ORDER[r.zone] ?? 9 : 1.5); // to-order shortages rank after red
  const rows = [...(data ?? [])].sort((a: any, b: any) => rank(a) - rank(b) || Number(b.priority_pct ?? 0) - Number(a.priority_pct ?? 0));
  const buy = rows.filter((r: any) => r.procurement_method === "BUY");
  const make = rows.filter((r: any) => r.procurement_method === "MAKE");
  const canBuy = access.full("PURCHASING");

  return (
    <section>
      <div className="page-head">
        <div>
          <h1>Replenishment</h1>
          <p className="muted">
            What to order today. Buffers: target − (on hand + on order − allocated). To order: open sales orders not covered by
            on hand + on order. Quantities rounded to the supplier&apos;s unit, minimum and multiple.
          </p>
        </div>
        <div className="spacer" />
        <Link href="/buffers">Buffer board</Link>
      </div>
      {error && <p className="msg err">{error.message}</p>}

      <h2>Buy</h2>
      <ActionForm action={createPurchaseOrders} resetOnSuccess={false}>
        <table className="grid">
          <thead>
            <tr>
              <th></th><th>Priority</th><th>Item</th><th>Wh.</th><th>Source</th><th className="num">Need (base)</th>
              <th>Supplier</th><th className="num">Lead time</th><th className="num">Order qty</th><th>Unit</th>
            </tr>
          </thead>
          <tbody>
            {buy.map((r: any, k: number) => (
              <tr key={`${r.item_id}-${r.warehouse_id}-${r.source}`} className={r.zone ? `row-${r.zone}` : ""}>
                <td>{r.business_partner_id && canBuy && <input type="checkbox" name="sel" value={k} defaultChecked={r.zone === "RED" || r.zone === "BLACK" || r.source === "TO_ORDER"} />}</td>
                <td>{r.source === "BUFFER" ? <><Zone zone={r.zone} /> <span className="small">{r.priority_pct}%</span></> : <span className="badge">order</span>}</td>
                <td><Link href={`/items/${r.item_id}`} className="mono">{r.item_code}</Link> <span className="small">{r.item_name}</span></td>
                <td className="mono">{r.warehouse_code}</td>
                <td className="small">{r.source === "BUFFER" ? `target ${fmt(r.target_qty)}` : `reserved ${fmt(r.allocated)}`} · on hand {fmt(r.on_hand)} · on order {fmt(r.on_order)}</td>
                <td className="num">{fmt(r.need_base)} <span className="mono small">{r.base_uom}</span></td>
                <td>{r.supplier_code ? <><span className="mono">{r.supplier_code}</span> <span className="small">{r.supplier_name}</span></> : <Link href={`/items/${r.item_id}`} className="small">set preferred supplier</Link>}</td>
                <td className="num">{r.lead_time_days ?? ""}</td>
                <td className="num">
                  <input type="hidden" name={`item_${k}`} value={r.item_id} />
                  <input type="hidden" name={`wh_${k}`} value={r.warehouse_id} />
                  <input type="hidden" name={`uom_${k}`} value={r.purchase_uom_id} />
                  <input type="hidden" name={`bp_${k}`} value={r.business_partner_id ?? ""} />
                  <input name={`qty_${k}`} type="number" step="any" min={0} defaultValue={Number(r.suggested_purchase_qty)} style={{ width: 90 }} />
                </td>
                <td className="mono">{r.purchase_uom}</td>
              </tr>
            ))}
            {buy.length === 0 && <tr><td colSpan={10} className="empty">Nothing to buy.</td></tr>}
          </tbody>
        </table>
        {canBuy && buy.length > 0 && (
          <div className="form-row" style={{ marginTop: 10 }}>
            <label className="narrow">PO type
              <select name="document_type_id">
                {(poTypes ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
            </label>
            <button type="submit" className="primary">Create draft POs for selected lines</button>
            <span className="muted small">One draft per supplier. Red and black lines are preselected.</span>
          </div>
        )}
      </ActionForm>

      <h2>Make</h2>
      <p className="muted small">Production orders come with the production module. Until then, use this list to plan what to make.</p>
      <table className="grid">
        <thead><tr><th>Priority</th><th>Item</th><th>Wh.</th><th>Source</th><th className="num">Need</th><th>Unit</th></tr></thead>
        <tbody>
          {make.map((r: any) => (
            <tr key={`${r.item_id}-${r.warehouse_id}-${r.source}`} className={r.zone ? `row-${r.zone}` : ""}>
              <td>{r.source === "BUFFER" ? <><Zone zone={r.zone} /> <span className="small">{r.priority_pct}%</span></> : <span className="badge">order</span>}</td>
              <td><Link href={`/items/${r.item_id}`} className="mono">{r.item_code}</Link> <span className="small">{r.item_name}</span></td>
              <td className="mono">{r.warehouse_code}</td>
              <td className="small">{r.source === "BUFFER" ? `target ${fmt(r.target_qty)}` : `reserved ${fmt(r.allocated)}`} · on hand {fmt(r.on_hand)}</td>
              <td className="num">{fmt(r.need_base)}</td>
              <td className="mono">{r.base_uom}</td>
            </tr>
          ))}
          {make.length === 0 && <tr><td colSpan={6} className="empty">Nothing to make.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
