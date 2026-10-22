import Link from "next/link";
import { notFound } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { fmt, money, statusClass } from "@/lib/format";
import { ActionForm } from "@/components/ActionForm";
import {
  addPoLine, cancelPo, closePo, deleteDraftPo, deletePoLine, receivePo, releasePo, updatePoHeader, updatePoLine,
} from "../actions";

export default async function PoPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, company } = await requireCompany();
  const access = await getAccess();

  const { data: po } = await supabase
    .from("purchase_orders")
    .select("*, business_partners(id, code, name), document_types(name)")
    .eq("id", id)
    .eq("company_id", company.id)
    .maybeSingle();
  if (!po) notFound();

  const seePrices = access.can("PURCHASE_PRICES");
  const editPrices = access.full("PURCHASE_PRICES");
  const canEdit = access.full("PURCHASING");
  const editable = canEdit && (po.status === "DRAFT" || po.status === "OPEN");

  const [{ data: lines }, { data: items }, { data: uoms }, { data: warehouses }, { data: reasons }, { data: currencies }, { data: grpoTypes }] =
    await Promise.all([
      supabase.from("purchase_order_lines")
        .select("*, items(item_code, name, uom_groups(base_uom_id))")
        .eq("purchase_order_id", id).order("line_no"),
      supabase.from("items").select("id, item_code, name").eq("company_id", company.id).eq("is_active", true).eq("is_template", false).order("item_code").limit(3000),
      supabase.from("uoms").select("id, code").eq("company_id", company.id).order("code"),
      supabase.from("warehouses").select("id, code").eq("company_id", company.id).eq("is_active", true).order("code"),
      supabase.from("reason_codes").select("id, reason_type, code, name").eq("company_id", company.id).eq("is_active", true)
        .in("reason_type", ["PO_CLOSE", "CANCELLATION"]).order("code"),
      supabase.from("currencies").select("code").eq("is_active", true).order("code"),
      supabase.from("document_types").select("id, name").eq("company_id", company.id).eq("category", "GOODS_RECEIPT_PO").eq("is_active", true).order("code"),
    ]);

  const lineIds = (lines ?? []).map((l: any) => l.id);
  const [{ data: prices }, { data: receiptLines }] = await Promise.all([
    seePrices && lineIds.length
      ? supabase.from("purchase_order_line_prices").select("purchase_order_line_id, unit_price, discount_pct").in("purchase_order_line_id", lineIds)
      : Promise.resolve({ data: [] as any[] }),
    lineIds.length
      ? supabase.from("inventory_document_lines").select("document_id, inventory_documents(id, doc_number, doc_date, status, reverses_document_id)").in("purchase_order_line_id", lineIds)
      : Promise.resolve({ data: [] as any[] }),
  ]);

  const price = new Map((prices ?? []).map((p: any) => [p.purchase_order_line_id, p]));
  const uomCode = new Map((uoms ?? []).map((u) => [u.id, u.code]));
  const whCode = new Map((warehouses ?? []).map((w) => [w.id, w.code]));
  const receipts = [...new Map((receiptLines ?? []).map((r: any) => [r.inventory_documents?.id, r.inventory_documents])).values()].filter(Boolean);
  const total = (lines ?? []).reduce((sum: number, l: any) => {
    const p: any = price.get(l.id);
    return p ? sum + Number(l.quantity) * Number(p.unit_price) * (1 - Number(p.discount_pct) / 100) : sum;
  }, 0);
  const missingPrices = seePrices && (lines ?? []).some((l: any) => !price.has(l.id));
  const today = new Date().toISOString().slice(0, 10);
  const byType = (t: string) => (reasons ?? []).filter((r) => r.reason_type === t);

  return (
    <section>
      <p className="muted small"><Link href="/purchasing">Purchase orders</Link></p>
      <h1>
        {po.document_types?.name} <span className="mono">{po.doc_number ?? "(draft)"}</span>{" "}
        <span className={`badge ${statusClass(po.status)}`}>{po.status}{po.close_type ? ` · ${po.close_type.toLowerCase()}` : ""}</span>
      </h1>
      <p className="muted">
        <Link href={`/partners/${po.business_partner_id}`} className="mono">{po.business_partners?.code}</Link> {po.business_partners?.name}
        {" · "}{po.currency_code}{po.exchange_rate && po.currency_code !== company.base_currency ? ` @ ${fmt(po.exchange_rate, 4)} ${company.base_currency}` : ""}
      </p>

      {/* Header */}
      <div className="panel">
        <ActionForm action={updatePoHeader} resetOnSuccess={false}>
          <input type="hidden" name="id" value={po.id} />
          <input type="hidden" name="status" value={po.status} />
          <div className="form-row">
            <label className="narrow">Date<input name="doc_date" type="date" defaultValue={po.doc_date} disabled={po.status !== "DRAFT"} /></label>
            <label className="narrow">Currency
              <select name="currency_code" defaultValue={po.currency_code ?? ""} disabled={po.status !== "DRAFT"}>
                {(currencies ?? []).map((c) => <option key={c.code} value={c.code}>{c.code}</option>)}
              </select>
            </label>
            <label className="narrow">Required by<input name="required_date" type="date" defaultValue={po.required_date ?? ""} /></label>
            <label>Supplier reference<input name="supplier_reference" defaultValue={po.supplier_reference ?? ""} /></label>
            <label className="wide">Remarks<input name="remarks" defaultValue={po.remarks ?? ""} /></label>
            {editable && <button type="submit">Save header</button>}
          </div>
        </ActionForm>
      </div>

      {/* Lines */}
      <h2>Lines</h2>
      <table className="grid">
        <thead>
          <tr>
            <th className="num">#</th><th>Item</th><th className="num">Ordered</th><th className="num">Received</th>
            <th>Warehouse</th><th>Required</th><th>Expected</th>{seePrices && <th className="num">Price / disc %</th>}<th></th>
          </tr>
        </thead>
        <tbody>
          {(lines ?? []).map((l: any) => {
            const p: any = price.get(l.id);
            const factor = Number(l.quantity) / Number(l.quantity_base); // line unit per base unit
            const receivedInLineUnit = Number(l.received_qty_base) * factor;
            const lineOpen = l.line_status === "OPEN" && Number(l.received_qty_base) < Number(l.quantity_base);
            const late = lineOpen && l.expected_date && l.expected_date < today;
            return (
              <tr key={l.id}>
                <td className="num">{l.line_no}</td>
                <td>
                  <Link href={`/items/${l.item_id}`} className="mono">{l.items?.item_code}</Link> <span className="small">{l.items?.name}</span>
                  {l.supplier_item_code && <div className="small muted">supplier code {l.supplier_item_code}</div>}
                  {l.line_status === "CLOSED" && <span className="badge CANCELLED">closed</span>}
                </td>
                {editable && l.line_status === "OPEN" ? (
                  <td colSpan={seePrices ? 6 : 5}>
                    <ActionForm action={updatePoLine} resetOnSuccess={false}>
                      <input type="hidden" name="id" value={l.id} />
                      <input type="hidden" name="purchase_order_id" value={po.id} />
                      <div className="form-row">
                        <input name="quantity" type="number" step="any" min={0} defaultValue={Number(l.quantity)} style={{ width: 90 }} />
                        <span className="mono" style={{ alignSelf: "center" }}>{uomCode.get(l.uom_id)}</span>
                        <span className="small" style={{ alignSelf: "center", width: 90 }}>rcvd {fmt(receivedInLineUnit, 3)}</span>
                        <span className="mono small" style={{ alignSelf: "center" }}>{whCode.get(l.warehouse_id)}</span>
                        <input name="required_date" type="date" defaultValue={l.required_date ?? ""} />
                        <input name="expected_date" type="date" defaultValue={l.expected_date ?? ""} style={late ? { borderColor: "var(--err)" } : undefined} />
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
                    <td className="num">{fmt(receivedInLineUnit, 3)}</td>
                    <td className="mono">{whCode.get(l.warehouse_id)}</td>
                    <td>{l.required_date}</td>
                    <td>{l.expected_date}</td>
                    {seePrices && <td className="num">{p ? `${money(p.unit_price)} / ${Number(p.discount_pct)}` : "—"}</td>}
                  </>
                )}
                <td className="num">
                  {editable && po.status === "DRAFT" && (
                    <ActionForm action={deletePoLine}>
                      <input type="hidden" name="id" value={l.id} />
                      <input type="hidden" name="purchase_order_id" value={po.id} />
                      <button type="submit" className="link">Remove</button>
                    </ActionForm>
                  )}
                  {editable && po.status === "OPEN" && lineOpen && byType("PO_CLOSE").length > 0 && (
                    <ActionForm action={closePo} confirm="Close this line? The rest will no longer be expected.">
                      <input type="hidden" name="purchase_order_id" value={po.id} />
                      <input type="hidden" name="line_id" value={l.id} />
                      <input type="hidden" name="reason_id" value={byType("PO_CLOSE")[0].id} />
                      <button type="submit" className="link">Close line</button>
                    </ActionForm>
                  )}
                </td>
              </tr>
            );
          })}
          {(lines ?? []).length === 0 && <tr><td colSpan={9} className="empty">No lines yet.</td></tr>}
        </tbody>
      </table>
      {seePrices && (lines ?? []).length > 0 && (
        <p className="num" style={{ marginTop: 6 }}>
          Total <strong>{money(total, po.currency_code)}</strong>
          {po.exchange_rate && po.currency_code !== company.base_currency && <> · {money(total * Number(po.exchange_rate), company.base_currency)}</>}
          {missingPrices && <span className="muted small"> (some lines have no price)</span>}
        </p>
      )}

      {editable && (
        <div className="panel" style={{ marginTop: 10 }}>
          <strong>Add line</strong>
          <ActionForm action={addPoLine}>
            <input type="hidden" name="purchase_order_id" value={po.id} />
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
                  <option value="">Purchase unit</option>
                  {(uoms ?? []).map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                </select>
              </label>
              <label className="narrow">Warehouse
                <select name="warehouse_id" defaultValue="">
                  <option value="">Default</option>
                  {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
                </select>
              </label>
              <label className="narrow">Required<input name="required_date" type="date" /></label>
              <label className="narrow">Expected<input name="expected_date" type="date" title="Empty = PO date + lead time" /></label>
              {editPrices && <label className="narrow">Price<input name="unit_price" type="number" step="any" min={0} /></label>}
              {editPrices && <label className="narrow">Disc %<input name="discount_pct" type="number" step="any" min={0} max={100} defaultValue={0} /></label>}
              <button type="submit" className="primary">Add</button>
            </div>
            <p className="muted small">Unit, supplier code and expected date default from the item–supplier data.</p>
          </ActionForm>
        </div>
      )}

      {/* Actions */}
      {canEdit && po.status === "DRAFT" && (
        <div className="panel">
          <div className="form-row">
            <ActionForm action={releasePo} resetOnSuccess={false}>
              <input type="hidden" name="purchase_order_id" value={po.id} />
              <button type="submit" className="primary">Release purchase order</button>
            </ActionForm>
            <ActionForm action={deleteDraftPo} confirm="Delete this draft?">
              <input type="hidden" name="purchase_order_id" value={po.id} />
              <button type="submit" className="danger">Delete draft</button>
            </ActionForm>
          </div>
        </div>
      )}

      {po.status === "OPEN" && access.full("INVENTORY") && (
        <div className="panel">
          <strong>Receive goods</strong> <span className="muted small">Creates a goods receipt PO draft with all open quantities; adjust, then post.</span>
          <ActionForm action={receivePo} resetOnSuccess={false}>
            <input type="hidden" name="purchase_order_id" value={po.id} />
            <div className="form-row" style={{ marginTop: 8 }}>
              <label className="narrow">Type
                <select name="document_type_id">
                  {(grpoTypes ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                </select>
              </label>
              <label className="narrow">Receipt date<input name="doc_date" type="date" defaultValue={today} required /></label>
              <label>Supplier delivery note<input name="reference" /></label>
              <button type="submit" className="primary">Create receipt</button>
            </div>
          </ActionForm>
        </div>
      )}

      {canEdit && po.status === "OPEN" && (
        <div className="panel">
          <div className="form-row">
            <ActionForm action={closePo} confirm="Close the whole PO? Remaining quantities will no longer be expected.">
              <input type="hidden" name="purchase_order_id" value={po.id} />
              <div className="form-row">
                <label>Close reason
                  <select name="reason_id" required>
                    <option value="">—</option>
                    {byType("PO_CLOSE").map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                  </select>
                </label>
                <button type="submit">Close PO</button>
              </div>
            </ActionForm>
            <ActionForm action={cancelPo} confirm="Cancel this PO?">
              <input type="hidden" name="purchase_order_id" value={po.id} />
              <div className="form-row">
                <label>Cancel reason
                  <select name="reason_id" required>
                    <option value="">—</option>
                    {byType("CANCELLATION").map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                  </select>
                </label>
                <button type="submit" className="danger">Cancel PO</button>
              </div>
            </ActionForm>
          </div>
          {byType("PO_CLOSE").length === 0 && <p className="muted small">Add a reason in the &quot;Purchase order closed short&quot; group to close POs or lines.</p>}
        </div>
      )}

      <h2>Receipts</h2>
      <table className="grid" style={{ maxWidth: 640 }}>
        <thead><tr><th>Number</th><th>Date</th><th>Status</th></tr></thead>
        <tbody>
          {receipts.map((r: any) => (
            <tr key={r.id}>
              <td className="mono"><Link href={`/inventory/${r.id}`}>{r.doc_number ?? "(draft)"}</Link>{r.reverses_document_id && " (reversal)"}</td>
              <td>{r.doc_date}</td>
              <td><span className={`badge ${r.status}`}>{r.status}</span></td>
            </tr>
          ))}
          {receipts.length === 0 && <tr><td colSpan={3} className="empty">No receipts yet.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
