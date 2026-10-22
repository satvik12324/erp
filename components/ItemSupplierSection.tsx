import Link from "next/link";
import { ActionForm } from "@/components/ActionForm";
import { deleteItemSupplier, upsertItemSupplier } from "@/app/(app)/partners/actions";

type Opt = { id: string; code: string; name?: string };

// Item–supplier rows with planned vs actual lead time. Used on the partner page (fixed partner,
// pick an item) and on the item page (fixed item, pick a supplier).
export function ItemSupplierSection({
  mode, fixedId, rows, options, uoms, stats, canEdit,
}: {
  mode: "partner" | "item";
  fixedId: string;
  rows: any[];
  options: Opt[];
  uoms: Opt[];
  stats: Map<string, any>;
  canEdit: boolean;
}) {
  const uomCode = new Map(uoms.map((u) => [u.id, u.code]));
  return (
    <>
      <table className="grid">
        <thead>
          <tr>
            <th>{mode === "partner" ? "Item" : "Supplier"}</th><th>Supplier code</th><th>Unit</th>
            <th className="num">Min / multiple</th><th className="num">Planned</th><th className="num">Actual avg / p80</th>
            <th className="num">On time</th><th></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const s = stats.get(mode === "partner" ? r.item_id : r.business_partner_id);
            const other = mode === "partner" ? r.items : r.business_partners;
            return (
              <tr key={r.id}>
                <td>
                  <Link className="mono" href={mode === "partner" ? `/items/${r.item_id}` : `/partners/${r.business_partner_id}`}>{other?.item_code ?? other?.code}</Link>{" "}
                  <span className="small">{other?.name}</span> {r.is_preferred && <span className="badge">preferred</span>}
                </td>
                <td className="mono">{r.supplier_item_code}</td>
                <td className="mono">{r.purchase_uom_id ? uomCode.get(r.purchase_uom_id) : <span className="muted">item&apos;s</span>}</td>
                <td className="num">{[r.min_order_qty, r.order_multiple].map((x) => (x == null ? "–" : Number(x))).join(" / ")}</td>
                <td className="num">{r.lead_time_days != null ? `${r.lead_time_days} d` : "–"}</td>
                <td className="num">{s ? `${s.avg_days} / ${Number(s.p80_days)} d (${s.receipts})` : <span className="muted">no receipts</span>}</td>
                <td className="num">{s?.on_time_pct != null ? `${s.on_time_pct}%` : ""}</td>
                <td className="num">
                  {canEdit && (
                    <ActionForm action={deleteItemSupplier} confirm="Remove this item–supplier link?">
                      <input type="hidden" name="id" value={r.id} />
                      <input type="hidden" name="item_id" value={r.item_id} />
                      <input type="hidden" name="business_partner_id" value={r.business_partner_id} />
                      <button type="submit" className="link">Remove</button>
                    </ActionForm>
                  )}
                </td>
              </tr>
            );
          })}
          {rows.length === 0 && <tr><td colSpan={8} className="empty">None yet.</td></tr>}
        </tbody>
      </table>
      {canEdit && (
        <div className="panel" style={{ marginTop: 10 }}>
          <ActionForm action={upsertItemSupplier}>
            <input type="hidden" name={mode === "partner" ? "business_partner_id" : "item_id"} value={fixedId} />
            <div className="form-row">
              <label className="wide">{mode === "partner" ? "Item" : "Supplier"}
                <select name={mode === "partner" ? "item_id" : "business_partner_id"} required>
                  <option value="">—</option>
                  {options.map((o) => <option key={o.id} value={o.id}>{o.code} · {o.name}</option>)}
                </select>
              </label>
              <label>Supplier code<input name="supplier_item_code" /></label>
              <label className="narrow">Purchase unit
                <select name="purchase_uom_id" defaultValue="">
                  <option value="">Item&apos;s</option>
                  {uoms.map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                </select>
              </label>
              <label className="narrow">Min qty<input name="min_order_qty" type="number" step="any" min={0} /></label>
              <label className="narrow">Multiple<input name="order_multiple" type="number" step="any" min={0} /></label>
              <label className="narrow">Lead time (d)<input name="lead_time_days" type="number" min={0} /></label>
              <label className="check"><input type="checkbox" name="is_preferred" />Preferred</label>
              <button type="submit" className="primary">Save</button>
            </div>
            <p className="muted small">Saving an existing pair updates it.</p>
          </ActionForm>
        </div>
      )}
    </>
  );
}
