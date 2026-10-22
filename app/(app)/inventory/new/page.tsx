import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { createDocument } from "../actions";

export default async function NewInventoryDocPage() {
  const { supabase, company } = await requireCompany();
  const [{ data: types }, { data: reasons }, { data: partners }] = await Promise.all([
    supabase.from("document_types").select("id, code, name, category").eq("company_id", company.id).eq("is_active", true)
      .in("category", ["GOODS_RECEIPT", "GOODS_RECEIPT_PO", "GOODS_ISSUE", "INVENTORY_TRANSFER", "RECEIPT_FROM_PRODUCTION", "DELIVERY"]).order("code"),
    supabase.from("reason_codes").select("id, reason_type, code, name").eq("company_id", company.id).eq("is_active", true)
      .in("reason_type", ["OPENING_STOCK", "STOCK_ADJUSTMENT"]).order("code"),
    supabase.from("business_partners").select("id, code, name").eq("company_id", company.id).eq("is_active", true)
      .order("code"),
  ]);
  const today = new Date().toISOString().slice(0, 10);

  if ((types ?? []).length === 0)
    return (
      <section>
        <h1>New inventory document</h1>
        <p className="msg err">No inventory document types exist. <Link href="/setup/numbering">Create document types</Link> first.</p>
      </section>
    );

  return (
    <section>
      <h1>New inventory document</h1>
      <p className="muted">The document is created as a draft. Add lines, then post.</p>
      <div className="panel">
        <ActionForm action={createDocument} resetOnSuccess={false}>
          <div className="form-grid">
            <label>Type
              <select name="document_type_id" required>
                {(types ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
            </label>
            <label>Date<input name="doc_date" type="date" defaultValue={today} required /></label>
            <label>Business partner (supplier on goods receipt PO, customer on delivery)
              <select name="business_partner_id" defaultValue="">
                <option value="">—</option>
                {(partners ?? []).map((s) => <option key={s.id} value={s.id}>{s.code} · {s.name}</option>)}
              </select>
            </label>
            <label>Reason
              <select name="reason_code_id" defaultValue="">
                <option value="">—</option>
                {(reasons ?? []).map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
              </select>
            </label>
            <label>Reference<input name="reference" /></label>
            <label style={{ gridColumn: "span 2" }}>Remarks<input name="remarks" /></label>
          </div>
          <p style={{ marginTop: 12 }}><button type="submit" className="primary">Create draft</button></p>
        </ActionForm>
      </div>
    </section>
  );
}
