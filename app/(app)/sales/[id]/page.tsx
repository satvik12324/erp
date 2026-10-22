import Link from "next/link";
import { notFound } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { fmt, money, statusClass } from "@/lib/format";
import { ActionForm } from "@/components/ActionForm";
import { Meter, Zone } from "@/components/Zone";
import {
  addSoLine, cancelSo, closeSo, deleteDraftSo, deleteSoLine, deliverSo, releaseSo, updateSoHeader, updateSoLine,
} from "../actions";

export default async function SoPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, company } = await requireCompany();
  const access = await getAccess();

  const { data: so } = await supabase
    .from("sales_orders")
    .select("*, business_partners(id, code, name), document_types(name)")
    .eq("id", id)
    .eq("company_id", company.id)
    .maybeSingle();
  if (!so) notFound();

  const seePrices = access.can("SALES_PRICES");
  const editPrices = access.full("SALES_PRICES");
  const canEdit = access.full("SALES");
  const editable = canEdit && (so.status === "DRAFT" || so.status === "OPEN");

  const [{ data: lines }, { data: items }, { data: uoms }, { data: warehouses }, { data: reasons }, { data: currencies }, { data: dlvTypes }, { data: buffer }, { data: stock }] =
    await Promise.all([
      supabase.from("sales_order_lines").select("*, items(item_code, name)").eq("sales_order_id", id).order("line_no"),
      supabase.from("items").select("id, item_code, name").eq("company_id", company.id).eq("is_active", true).eq("is_template", false)
        .eq("is_sold", true).order("item_code").limit(3000),
      supabase.from("uoms").select("id, code").eq("company_id", company.id).order("code"),
      supabase.from("warehouses").select("id, code").eq("company_id", company.id).eq("is_active", true).order("code"),
      supabase.from("reason_codes").select("id, reason_type, code, name").eq("company_id", company.id).eq("is_active", true)
        .in("reason_type", ["SO_CLOSE", "CANCELLATION"]).order("code"),
      supabase.from("currencies").select("code").eq("is_active", true).order("code"),
      supabase.from("document_types").select("id, name").eq("company_id", company.id).eq("category", "DELIVERY").eq("is_active", true).order("code"),
      supabase.from("v_sales_order_buffer").select("*").eq("sales_order_id", id).maybeSingle(),
      supabase.from("item_warehouse_stock").select("item_id, warehouse_id, on_hand").eq("company_id", company.id),
    ]);

  const lineIds = (lines ?? []).map((l: any) => l.id);
  const [{ data: prices }, { data: dlvLines }] = await Promise.all([
    seePrices && lineIds.length
      ? supabase.from("sales_order_line_prices").select("sales_order_line_id, unit_price, discount_pct").in("sales_order_line_id", lineIds)
      : Promise.resolve({ data: [] as any[] }),
    lineIds.length
      ? supabase.from("inventory_document_lines").select("document_id, inventory_documents(id, doc_number, doc_date, status, reverses_document_id)").in("sales_order_line_id", lineIds)
      : Promise.resolve({ data: [] as any[] }),
  ]);

  const price = new Map((prices ?? []).map((p: any) => [p.sales_order_line_id, p]));
  const uomCode = new Map((uoms ?? []).map((u) => [u.id, u.code]));
  const whCode = new Map((warehouses ?? []).map((w) => [w.id, w.code]));
  const onHand = new Map((stock ?? []).map((s: any) => [`${s.item_id}-${s.warehouse_id}`, Number(s.on_hand)]));
  const deliveries = [...new Map((dlvLines ?? []).map((r: any) => [r.inventory_documents?.id, r.inventory_documents])).values()].filter(Boolean);
  const total = (lines ?? []).reduce((sum: number, l: any) => {
    const p: any = price.get(l.id);
    return p ? sum + Number(l.quantity) * Number(p.unit_price) * (1 - Number(p.discount_pct) / 100) : sum;
  }, 0);
  const missingPrices = seePrices && (lines ?? []).some((l: any) => !price.has(l.id));
  const today = new Date().toISOString().slice(0, 10);
  const byType = (t: string) => (reasons ?? []).filter((r) => r.reason_type === t);

  return (
    <section>
      <p className="muted small"><Link href="/sales">Sales orders</Link> · <Link href="/sales/board">Order board</Link></p>
      <h1>
        {so.document_types?.name} <span className="mono">{so.doc_number ?? "(draft)"}</span>{" "}
        <span className={`badge ${statusClass(so.status)}`}>{so.status}{so.close_type ? ` · ${so.close_type.toLowerCase()}` : ""}</span>
      </h1>
      <p className="muted">
        <Link href={`/partners/${so.business_partner_id}`} className="mono">{so.business_partners?.code}</Link> {so.business_partners?.name}
        {" · "}{so.currency_code}{so.exchange_rate && so.currency_code !== company.base_currency ? ` @ ${fmt(so.exchange_rate, 4)} ${company.base_currency}` : ""}
      </p>

      {buffer && (
        <div className="panel">
          <div className="form-row" style={{ alignItems: "center" }}>
            <strong>Time buffer</strong> <Zone zone={buffer.zone} /> <Meter pct={buffer.penetration} zone={buffer.zone} />
            <span className="small">
              {buffer.time_buffer_days} days, started {buffer.buffer_start} · due {buffer.due_date}
              {" "}({buffer.days_to_due >= 0 ? `${buffer.days_to_due} days left` : `${-buffer.days_to_due} days late`})
            </span>
            <span className="small">{buffer.stock_covered ? "· all open lines covered by stock on hand" : "· not all lines covered by stock on hand"}</span>
          </div>
        </div>
      )}

      {/* Header */}
      <div className="panel">
        <ActionForm action={updateSoHeader} resetOnSuccess={false}>
          <input type="hidden" name="id" value={so.id} />
          <input type="hidden" name="status" value={so.status} />
          <div className="form-row">
            <label className="narrow">Order date<input name="doc_date" type="date" defaultValue={so.doc_date} disabled={so.status !== "DRAFT"} /></label>
            <label className="narrow">Currency
              <select name="currency_code" defaultValue={so.currency_code ?? ""} disabled={so.status !== "DRAFT"}>
                {(currencies ?? []).map((c) => <option key={c.code} value={c.code}>{c.code}</option>)}
              </select>
            </label>
            <label className="narrow">Due date<input name="due_date" type="date" defaultValue={so.due_date ?? ""} /></label>
            <label className="narrow">Buffer days<input name="time_buffer_days" type="number" min={1} defaultValue={so.time_buffer_days ?? ""} placeholder="default" /></label>
            <label>Customer reference<input name="customer_reference" defaultValue={so.customer_reference ?? ""} /></label>
            <label className="wide">Remarks<input name="remarks" defaultValue={so.remarks ?? ""} /></label>
            {editable && <button type="submit">Save header</button>}
          </div>
        </ActionForm>
      </div>

      {/* Lines */}
      <h2>Lines</h2>
      <table className="grid">
        <thead>
          <tr>
            <th className="num">#</th><th>Item</th><th className="num">Ordered</th><th className="num">Delivered</th>
            <th>Warehouse</th><th className="num">On hand</th>{seePrices && <th className="num">Price / disc %</th>}<th></th>
          </tr>
        </thead>
        <tbody>
          {(lines ?? []).map((l: any) => {
            const p: any = price.get(l.id);
            const factor = Number(l.quantity) / Number(l.quantity_base);
            const deliveredInLineUnit = Number(l.delivered_qty_base) * factor;
            const openBase = Number(l.quantity_base) - Number(l.delivered_qty_base);
            const lineOpen = l.line_status === "OPEN" && openBase > 0;
            const oh = onHand.get(`${l.item_id}-${l.warehouse_id}`) ?? 0;
            return (
              <tr key={l.id}>
                <td className="num">{l.line_no}</td>
                <td>
                  <Link href={`/items/${l.item_id}`} className="mono">{l.items?.item_code}</Link> <span className="small">{l.items?.name}</span>
                  {l.line_status === "CLOSED" && <span className="badge CANCELLED">closed</span>}
                </td>
                {editable && l.line_status === "OPEN" ? (
                  <td colSpan={seePrices ? 5 : 4}>
                    <ActionForm action={updateSoLine} resetOnSuccess={false}>
                      <input type="hidden" name="id" value={l.id} />
                      <input type="hidden" name="sales_order_id" value={so.id} />
                      <div className="form-row">
                        <input name="quantity" type="number" step="any" min={0} defaultValue={Number(l.quantity)} style={{ width: 90 }} />
                        <span className="mono" style={{ alignSelf: "center" }}>{uomCode.get(l.uom_id)}</span>
                        <span className="small" style={{ alignSelf: "center", width: 90 }}>dlvd {fmt(deliveredInLineUnit, 3)}</span>
                        <span className="mono small" style={{ alignSelf: "center" }}>{whCode.get(l.warehouse_id)}</span>
                        <span className="small" style={{ alignSelf: "center", width: 110 }}>
                          on hand {fmt(oh)}{lineOpen && oh < openBase ? <span className="badge neg">short {fmt(openBase - oh)}</span> : null}
                        </span>
                        {editPrices && (
                          <>
                            <input name="unit_price" type="number" step="any" min={0} defaultValue={p ? Number(p.unit_price) : ""} placeholder="price" style={{ width: 90 }} />
                            <input name="discount_pct" type="number" step="any" min={0} max={100} defaultValue={p ? Number(p.discount_pct) : 0} style={{ width: 60 }} />
                          </>
                        )}
                        {seePrices && !editPrices && <span className="num" style={{ alignSelf: "center" }}>{p ? money(p.unit_price) : "—"}</span>}
                        <button type="submit">Update</button>
                      </div>
                    </ActionForm>
                  </td>
                ) : (
                  <>
                    <td className="num">{fmt(l.quantity)} <span className="mono small">{uomCode.get(l.uom_id)}</span></td>
                    <td className="num">{fmt(deliveredInLineUnit, 3)}</td>
                    <td className="mono">{whCode.get(l.warehouse_id)}</td>
                    <td className="num">{fmt(oh)}</td>
                    {seePrices && <td className="num">{p ? `${money(p.unit_price)} / ${Number(p.discount_pct)}` : "—"}</td>}
                  </>
                )}
                <td className="num">
                  {editable && so.status === "DRAFT" && (
                    <ActionForm action={deleteSoLine}>
                      <input type="hidden" name="id" value={l.id} />
                      <input type="hidden" name="sales_order_id" value={so.id} />
                      <button type="submit" className="link">Remove</button>
                    </ActionForm>
                  )}
                  {editable && so.status === "OPEN" && lineOpen && byType("SO_CLOSE").length > 0 && (
                    <ActionForm action={closeSo} confirm="Close this line? The rest will no longer be delivered or reserved.">
                      <input type="hidden" name="sales_order_id" value={so.id} />
                      <input type="hidden" name="line_id" value={l.id} />
                      <input type="hidden" name="reason_id" value={byType("SO_CLOSE")[0].id} />
                      <button type="submit" className="link">Close line</button>
                    </ActionForm>
                  )}
                </td>
              </tr>
            );
          })}
          {(lines ?? []).length === 0 && <tr><td colSpan={8} className="empty">No lines yet.</td></tr>}
        </tbody>
      </table>
      <p className="muted small">On hand is per line warehouse, before other orders; quantities in the item&apos;s base unit.</p>
      {seePrices && (lines ?? []).length > 0 && (
        <p className="num" style={{ marginTop: 6 }}>
          Total <strong>{money(total, so.currency_code)}</strong>
          {so.exchange_rate && so.currency_code !== company.base_currency && <> · {money(total * Number(so.exchange_rate), company.base_currency)}</>}
          {missingPrices && <span className="muted small"> (some lines have no price)</span>}
        </p>
      )}

      {editable && (
        <div className="panel" style={{ marginTop: 10 }}>
          <strong>Add line</strong>
          <ActionForm action={addSoLine}>
            <input type="hidden" name="sales_order_id" value={so.id} />
            <div className="form-row" style={{ marginTop: 8 }}>
              <label className="wide">Item
                <select name="item_id" required>
                  <option value="">—</option>
                  {(items ?? []).map((i) => <option key={i.id} value={i.id}>{i.item_code} · {i.name}</option>)}
                </select>
              </label>
              <label className="narrow">Quantity<input name="quantity" type="number" step="any" min={0} required /></label>
              <label className="narrow">Unit
                <select name="uom_id" defaultValue="">
                  <option value="">Sales unit</option>
                  {(uoms ?? []).map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                </select>
              </label>
              <label className="narrow">Warehouse
                <select name="warehouse_id" defaultValue="">
                  <option value="">Default</option>
                  {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
                </select>
              </label>
              {editPrices && <label className="narrow">Price<input name="unit_price" type="number" step="any" min={0} /></label>}
              {editPrices && <label className="narrow">Disc %<input name="discount_pct" type="number" step="any" min={0} max={100} defaultValue={0} /></label>}
              <button type="submit" className="primary">Add</button>
            </div>
          </ActionForm>
        </div>
      )}

      {/* Actions */}
      {canEdit && so.status === "DRAFT" && (
        <div className="panel">
          <div className="form-row">
            <ActionForm action={releaseSo} resetOnSuccess={false}>
              <input type="hidden" name="sales_order_id" value={so.id} />
              <button type="submit" className="primary">Release sales order</button>
            </ActionForm>
            <ActionForm action={deleteDraftSo} confirm="Delete this draft?">
              <input type="hidden" name="sales_order_id" value={so.id} />
              <button type="submit" className="danger">Delete draft</button>
            </ActionForm>
          </div>
          <p className="muted small">Release numbers the order, fixes the exchange rate and starts its time buffer clock. Open orders reserve stock.</p>
        </div>
      )}

      {so.status === "OPEN" && access.full("INVENTORY") && (
        <div className="panel">
          <strong>Deliver</strong> <span className="muted small">Creates a delivery draft with all open quantities; adjust to what ships, then post.</span>
          <ActionForm action={deliverSo} resetOnSuccess={false}>
            <input type="hidden" name="sales_order_id" value={so.id} />
            <div className="form-row" style={{ marginTop: 8 }}>
              <label className="narrow">Type
                <select name="document_type_id">
                  {(dlvTypes ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                </select>
              </label>
              <label className="narrow">Delivery date<input name="doc_date" type="date" defaultValue={today} required /></label>
              <label>Reference (vehicle, LR no.)<input name="reference" /></label>
              <button type="submit" className="primary">Create delivery</button>
            </div>
          </ActionForm>
        </div>
      )}

      {canEdit && so.status === "OPEN" && (
        <div className="panel">
          <div className="form-row">
            <ActionForm action={closeSo} confirm="Close the whole order? Remaining quantities will no longer be delivered or reserved.">
              <input type="hidden" name="sales_order_id" value={so.id} />
              <div className="form-row">
                <label>Close reason
                  <select name="reason_id" required>
                    <option value="">—</option>
                    {byType("SO_CLOSE").map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                  </select>
                </label>
                <button type="submit">Close order</button>
              </div>
            </ActionForm>
            <ActionForm action={cancelSo} confirm="Cancel this order?">
              <input type="hidden" name="sales_order_id" value={so.id} />
              <div className="form-row">
                <label>Cancel reason
                  <select name="reason_id" required>
                    <option value="">—</option>
                    {byType("CANCELLATION").map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                  </select>
                </label>
                <button type="submit" className="danger">Cancel order</button>
              </div>
            </ActionForm>
          </div>
          {byType("SO_CLOSE").length === 0 && <p className="muted small">Add a reason in the &quot;Sales order closed short&quot; group to close orders or lines.</p>}
        </div>
      )}

      <h2>Deliveries</h2>
      <table className="grid" style={{ maxWidth: 640 }}>
        <thead><tr><th>Number</th><th>Date</th><th>Status</th></tr></thead>
        <tbody>
          {deliveries.map((r: any) => (
            <tr key={r.id}>
              <td className="mono"><Link href={`/inventory/${r.id}`}>{r.doc_number ?? "(draft)"}</Link>{r.reverses_document_id && " (reversal)"}</td>
              <td>{r.doc_date}</td>
              <td><span className={`badge ${r.status}`}>{r.status}</span></td>
            </tr>
          ))}
          {deliveries.length === 0 && <tr><td colSpan={3} className="empty">No deliveries yet.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
