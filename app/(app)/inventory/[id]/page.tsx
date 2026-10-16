import Link from "next/link";
import { notFound } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import {
  addLine, cancelDocument, deleteDraft, deleteLine, fillProduction, postDocument, updateHeader, updateLineQty,
} from "../actions";

const fmt = (n: number | string) => Number(n).toLocaleString("en-IN", { maximumFractionDigits: 6 });
const CATEGORY: Record<string, string> = {
  GOODS_RECEIPT: "Goods receipt",
  GOODS_ISSUE: "Goods issue",
  INVENTORY_TRANSFER: "Inventory transfer",
  RECEIPT_FROM_PRODUCTION: "Receipt from production",
};

export default async function InventoryDocPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, company } = await requireCompany();

  const { data: doc } = await supabase
    .from("inventory_documents")
    .select("*, document_types(code, name)")
    .eq("id", id)
    .eq("company_id", company.id)
    .maybeSingle();
  if (!doc) notFound();

  const [{ data: lines }, { data: items }, { data: uoms }, { data: warehouses }, { data: reasons }, { data: links }, { data: moves }] =
    await Promise.all([
      supabase.from("inventory_document_lines")
        .select("id, line_no, item_id, direction, quantity, uom_id, quantity_base, warehouse_id, to_warehouse_id, remarks, items(item_code, name, uom_groups(base_uom_id))")
        .eq("document_id", id).order("line_no"),
      supabase.from("items").select("id, item_code, name").eq("company_id", company.id).eq("is_active", true)
        .eq("is_template", false).eq("item_type", "INVENTORY").order("item_code").limit(3000),
      supabase.from("uoms").select("id, code").eq("company_id", company.id).order("code"),
      supabase.from("warehouses").select("id, code, name").eq("company_id", company.id).eq("is_active", true).order("code"),
      supabase.from("reason_codes").select("id, reason_type, code, name").eq("company_id", company.id).eq("is_active", true).order("code"),
      supabase.from("inventory_documents").select("id, doc_number").in("id", [doc.reverses_document_id, doc.cancelled_by_document_id].filter(Boolean)),
      doc.status === "DRAFT"
        ? Promise.resolve({ data: [] as any[] })
        : supabase.from("stock_movements").select("id, item_id, warehouse_id, quantity_base, balance_after, override_reason_code_id").eq("document_id", id).order("id"),
    ]);

  const uomCode = new Map((uoms ?? []).map((u) => [u.id, u.code]));
  const whCode = new Map((warehouses ?? []).map((w) => [w.id, w.code]));
  const itemCode = new Map((items ?? []).map((i) => [i.id, i.item_code]));
  const linkNo = new Map((links ?? []).map((l) => [l.id, l.doc_number]));
  const reasonName = new Map((reasons ?? []).map((r) => [r.id, `${r.code} · ${r.name}`]));
  const byType = (t: string) => (reasons ?? []).filter((r) => r.reason_type === t);

  const draft = doc.status === "DRAFT";
  const isTransfer = doc.category === "INVENTORY_TRANSFER";
  const isProduction = doc.category === "RECEIPT_FROM_PRODUCTION";
  const headerReasons = (reasons ?? []).filter((r) => ["OPENING_STOCK", "STOCK_ADJUSTMENT", "CANCELLATION"].includes(r.reason_type));

  return (
    <section>
      <div className="page-head">
        <div>
          <p className="muted small"><Link href="/inventory">Inventory documents</Link> / {CATEGORY[doc.category]}</p>
          <h1>
            {doc.document_types?.name} <span className="mono">{doc.doc_number ?? "(draft)"}</span>{" "}
            <span className={`badge ${doc.status}`}>{doc.status}</span>
          </h1>
          <p className="muted small">
            {doc.reverses_document_id && <>Cancels <Link href={`/inventory/${doc.reverses_document_id}`}>{linkNo.get(doc.reverses_document_id)}</Link> · </>}
            {doc.cancelled_by_document_id && <>Cancelled by <Link href={`/inventory/${doc.cancelled_by_document_id}`}>{linkNo.get(doc.cancelled_by_document_id)}</Link> · </>}
            {doc.posted_at && <>Posted {new Date(doc.posted_at).toLocaleString("en-IN")}</>}
          </p>
        </div>
      </div>

      {/* Header */}
      <div className="panel">
        {draft ? (
          <ActionForm action={updateHeader} resetOnSuccess={false}>
            <input type="hidden" name="id" value={doc.id} />
            <div className="form-row">
              <label className="narrow">Date<input name="doc_date" type="date" defaultValue={doc.doc_date} required /></label>
              <label>Reason
                <select name="reason_code_id" defaultValue={doc.reason_code_id ?? ""}>
                  <option value="">—</option>
                  {headerReasons.map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                </select>
              </label>
              <label>Reference<input name="reference" defaultValue={doc.reference ?? ""} /></label>
              <label className="wide">Remarks<input name="remarks" defaultValue={doc.remarks ?? ""} /></label>
              <button type="submit">Save header</button>
            </div>
          </ActionForm>
        ) : (
          <div className="form-grid">
            <div><div className="muted small">Date</div>{doc.doc_date}</div>
            <div><div className="muted small">Reason</div>{doc.reason_code_id ? reasonName.get(doc.reason_code_id) : "—"}</div>
            <div><div className="muted small">Reference</div>{doc.reference ?? "—"}</div>
            <div><div className="muted small">Remarks</div>{doc.remarks ?? "—"}</div>
          </div>
        )}
      </div>

      {/* Fill from BOM */}
      {draft && isProduction && (
        <div className="panel">
          <strong>Fill from BOM</strong>{" "}
          <span className="muted small">Adds the product (+) and every backflush component (−) of its active BOM. Replaces existing lines.</span>
          <ActionForm action={fillProduction} resetOnSuccess={false}>
            <input type="hidden" name="document_id" value={doc.id} />
            <div className="form-row" style={{ marginTop: 8 }}>
              <label className="wide">Product
                <select name="item_id" required>
                  <option value="">—</option>
                  {(items ?? []).map((i) => <option key={i.id} value={i.id}>{i.item_code} · {i.name}</option>)}
                </select>
              </label>
              <label className="narrow">Quantity<input name="quantity" type="number" step="any" min={0} required /></label>
              <label className="narrow">UoM
                <select name="uom_id" defaultValue="">
                  <option value="">Item&apos;s</option>
                  {(uoms ?? []).map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                </select>
              </label>
              <label className="narrow">Into warehouse
                <select name="warehouse_id" defaultValue="">
                  <option value="">Item default</option>
                  {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
                </select>
              </label>
              <button type="submit" className="primary">Fill lines</button>
            </div>
          </ActionForm>
        </div>
      )}

      {/* Lines */}
      <h2>Lines</h2>
      <table className="grid">
        <thead>
          <tr>
            <th className="num">#</th><th>Item</th><th>{isProduction ? "In/Out" : ""}</th>
            <th className="num">Quantity</th><th>UoM</th><th className="num">Base qty</th>
            <th>{isTransfer ? "From" : "Warehouse"}</th>{isTransfer && <th>To</th>}<th></th>
          </tr>
        </thead>
        <tbody>
          {(lines ?? []).map((l: any) => (
            <tr key={l.id}>
              <td className="num">{l.line_no}</td>
              <td><Link href={`/items/${l.item_id}`} className="mono">{l.items?.item_code}</Link> <span className="small">{l.items?.name}</span></td>
              <td>{isProduction && <span className={`badge ${l.direction > 0 ? "POSTED" : "DRAFT"}`}>{l.direction > 0 ? "product +" : "component −"}</span>}</td>
              {draft ? (
                <td colSpan={4}>
                  <ActionForm action={updateLineQty} resetOnSuccess={false}>
                    <input type="hidden" name="id" value={l.id} />
                    <input type="hidden" name="document_id" value={doc.id} />
                    <div className="form-row">
                      <input name="quantity" type="number" step="any" min={0} defaultValue={Number(l.quantity)} style={{ width: 110 }} />
                      <span className="mono" style={{ alignSelf: "center" }}>{uomCode.get(l.uom_id)}</span>
                      <select name="warehouse_id" defaultValue={l.warehouse_id}>
                        {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
                      </select>
                      <button type="submit">Update</button>
                    </div>
                  </ActionForm>
                </td>
              ) : (
                <>
                  <td className="num">{fmt(l.quantity)}</td>
                  <td className="mono">{uomCode.get(l.uom_id)}</td>
                  <td className="num">{fmt(l.quantity_base)} {uomCode.get(l.items?.uom_groups?.base_uom_id)}</td>
                  <td className="mono">{whCode.get(l.warehouse_id)}</td>
                </>
              )}
              {isTransfer && <td className="mono">{whCode.get(l.to_warehouse_id)}</td>}
              <td className="num">
                {draft && (
                  <ActionForm action={deleteLine}>
                    <input type="hidden" name="id" value={l.id} />
                    <input type="hidden" name="document_id" value={doc.id} />
                    <button type="submit" className="link">Remove</button>
                  </ActionForm>
                )}
              </td>
            </tr>
          ))}
          {(lines ?? []).length === 0 && <tr><td colSpan={9} className="empty">No lines yet.</td></tr>}
        </tbody>
      </table>

      {draft && (
        <div className="panel" style={{ marginTop: 10 }}>
          <strong>Add line</strong>
          <ActionForm action={addLine}>
            <input type="hidden" name="document_id" value={doc.id} />
            <div className="form-row" style={{ marginTop: 8 }}>
              <label className="wide">Item
                <select name="item_id" required>
                  <option value="">—</option>
                  {(items ?? []).map((i) => <option key={i.id} value={i.id}>{i.item_code} · {i.name}</option>)}
                </select>
              </label>
              {isProduction && (
                <label className="narrow">In/Out
                  <select name="direction" defaultValue="-1">
                    <option value="-1">Component −</option>
                    <option value="1">Product +</option>
                  </select>
                </label>
              )}
              <label className="narrow">Quantity<input name="quantity" type="number" step="any" min={0} required /></label>
              <label className="narrow">UoM
                <select name="uom_id" defaultValue="">
                  <option value="">Item&apos;s</option>
                  {(uoms ?? []).map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                </select>
              </label>
              <label className="narrow">{isTransfer ? "From" : "Warehouse"}
                <select name="warehouse_id" defaultValue="">
                  <option value="">Default</option>
                  {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
                </select>
              </label>
              {isTransfer && (
                <label className="narrow">To
                  <select name="to_warehouse_id" required>
                    <option value="">—</option>
                    {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
                  </select>
                </label>
              )}
              <button type="submit" className="primary">Add</button>
            </div>
          </ActionForm>
        </div>
      )}

      {/* Post / delete draft */}
      {draft && (
        <div className="panel">
          <ActionForm action={postDocument} resetOnSuccess={false}>
            <input type="hidden" name="document_id" value={doc.id} />
            <div className="form-row">
              <label>Negative stock override (superuser, optional)
                <select name="override_reason_id" defaultValue="">
                  <option value="">No override — refuse if stock would go below zero</option>
                  {byType("NEGATIVE_STOCK_OVERRIDE").map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                </select>
              </label>
              <button type="submit" className="primary">Post document</button>
            </div>
          </ActionForm>
          <ActionForm action={deleteDraft} confirm="Delete this draft?">
            <input type="hidden" name="document_id" value={doc.id} />
            <p style={{ marginTop: 10 }}><button type="submit" className="danger">Delete draft</button></p>
          </ActionForm>
        </div>
      )}

      {/* Posted: movements + cancel */}
      {!draft && (
        <>
          <h2>Stock movements</h2>
          <table className="grid">
            <thead><tr><th>Item</th><th>Warehouse</th><th className="num">Change</th><th className="num">Balance after</th><th>Override</th></tr></thead>
            <tbody>
              {(moves ?? []).map((m: any) => (
                <tr key={m.id}>
                  <td className="mono">{itemCode.get(m.item_id) ?? "…"}</td>
                  <td className="mono">{whCode.get(m.warehouse_id)}</td>
                  <td className="num">{Number(m.quantity_base) > 0 ? "+" : ""}{fmt(m.quantity_base)}</td>
                  <td className={`num ${Number(m.balance_after) < 0 ? "badge neg" : ""}`}>{fmt(m.balance_after)}</td>
                  <td className="small">{m.override_reason_code_id ? reasonName.get(m.override_reason_code_id) : ""}</td>
                </tr>
              ))}
            </tbody>
          </table>

          {doc.status === "POSTED" && !doc.reverses_document_id && (
            <div className="panel" style={{ marginTop: 16 }}>
              <strong>Cancel document</strong>{" "}
              <span className="muted small">Posts a reversing document with today&apos;s date. The original stays for the audit trail.</span>
              <ActionForm action={cancelDocument} confirm="Cancel this document? A reversing document will be posted." resetOnSuccess={false}>
                <input type="hidden" name="document_id" value={doc.id} />
                <div className="form-row" style={{ marginTop: 8 }}>
                  <label>Reason
                    <select name="reason_code_id" required>
                      <option value="">—</option>
                      {byType("CANCELLATION").map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                    </select>
                  </label>
                  <label>Negative stock override (optional)
                    <select name="override_reason_id" defaultValue="">
                      <option value="">No override</option>
                      {byType("NEGATIVE_STOCK_OVERRIDE").map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                    </select>
                  </label>
                  <button type="submit" className="danger">Cancel document</button>
                </div>
              </ActionForm>
            </div>
          )}
        </>
      )}
    </section>
  );
}
