import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { createPo } from "../actions";

export default async function NewPoPage({ searchParams }: { searchParams: Promise<{ bp?: string }> }) {
  const { bp } = await searchParams;
  const { supabase, company } = await requireCompany();
  const [{ data: types }, { data: suppliers }, { data: currencies }] = await Promise.all([
    supabase.from("document_types").select("id, code, name").eq("company_id", company.id).eq("category", "PURCHASE_ORDER").eq("is_active", true).order("code"),
    supabase.from("business_partners").select("id, code, name").eq("company_id", company.id).in("bp_type", ["SUPPLIER", "BOTH"]).eq("is_active", true).order("code"),
    supabase.from("currencies").select("code").eq("is_active", true).order("code"),
  ]);
  const today = new Date().toISOString().slice(0, 10);

  if ((types ?? []).length === 0 || (suppliers ?? []).length === 0)
    return (
      <section>
        <h1>New purchase order</h1>
        {(types ?? []).length === 0 && <p className="msg err">No purchase order document type. <Link href="/setup/numbering">Create one</Link> (behaves as Purchase Order).</p>}
        {(suppliers ?? []).length === 0 && <p className="msg err">No suppliers. <Link href="/partners/new">Create a supplier</Link>.</p>}
      </section>
    );

  return (
    <section>
      <h1>New purchase order</h1>
      <p className="muted">Created as a draft. Add lines, then release to number it and fix the exchange rate.</p>
      <div className="panel">
        <ActionForm action={createPo} resetOnSuccess={false}>
          <div className="form-grid">
            <label style={{ gridColumn: "span 2" }}>Supplier
              <select name="business_partner_id" defaultValue={bp ?? ""} required>
                <option value="">—</option>
                {(suppliers ?? []).map((s) => <option key={s.id} value={s.id}>{s.code} · {s.name}</option>)}
              </select>
            </label>
            <label>Type
              <select name="document_type_id">
                {(types ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
            </label>
            <label>Date<input name="doc_date" type="date" defaultValue={today} required /></label>
            <label>Required by<input name="required_date" type="date" /></label>
            <label>Currency
              <select name="currency_code" defaultValue="">
                <option value="">Supplier default</option>
                {(currencies ?? []).map((c) => <option key={c.code} value={c.code}>{c.code}</option>)}
              </select>
            </label>
            <label>Supplier reference<input name="supplier_reference" placeholder="Quote / PI number" /></label>
            <label style={{ gridColumn: "span 2" }}>Remarks<input name="remarks" /></label>
          </div>
          <p style={{ marginTop: 12 }}><button type="submit" className="primary">Create draft</button></p>
        </ActionForm>
      </div>
    </section>
  );
}
