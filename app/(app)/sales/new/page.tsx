import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { createSo } from "../actions";

export default async function NewSoPage({ searchParams }: { searchParams: Promise<{ bp?: string }> }) {
  const { bp } = await searchParams;
  const { supabase, company } = await requireCompany();
  const [{ data: types }, { data: customers }, { data: currencies }, { data: settings }] = await Promise.all([
    supabase.from("document_types").select("id, code, name").eq("company_id", company.id).eq("category", "SALES_ORDER").eq("is_active", true).order("code"),
    supabase.from("business_partners").select("id, code, name").eq("company_id", company.id).in("bp_type", ["CUSTOMER", "BOTH"]).eq("is_active", true).order("code"),
    supabase.from("currencies").select("code").eq("is_active", true).order("code"),
    supabase.from("company_settings").select("default_time_buffer_days").eq("company_id", company.id).maybeSingle(),
  ]);
  const today = new Date().toISOString().slice(0, 10);

  if ((types ?? []).length === 0 || (customers ?? []).length === 0)
    return (
      <section>
        <h1>New sales order</h1>
        {(types ?? []).length === 0 && <p className="msg err">No sales order document type. <Link href="/setup/numbering">Create one</Link> (behaves as Sales Order).</p>}
        {(customers ?? []).length === 0 && <p className="msg err">No customers. <Link href="/partners/new">Create a customer</Link>.</p>}
      </section>
    );

  return (
    <section>
      <h1>New sales order</h1>
      <p className="muted">
        Created as a draft. The due date is the date promised to the customer; the order&apos;s time buffer starts
        that many days before it ({settings?.default_time_buffer_days ?? 14} days unless you enter another length).
      </p>
      <div className="panel">
        <ActionForm action={createSo} resetOnSuccess={false}>
          <div className="form-grid">
            <label style={{ gridColumn: "span 2" }}>Customer
              <select name="business_partner_id" defaultValue={bp ?? ""} required>
                <option value="">—</option>
                {(customers ?? []).map((c) => <option key={c.id} value={c.id}>{c.code} · {c.name}</option>)}
              </select>
            </label>
            <label>Type
              <select name="document_type_id">
                {(types ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
            </label>
            <label>Order date<input name="doc_date" type="date" defaultValue={today} required /></label>
            <label>Due date (promised)<input name="due_date" type="date" /></label>
            <label>Time buffer (days)<input name="time_buffer_days" type="number" min={1} placeholder={String(settings?.default_time_buffer_days ?? 14)} /></label>
            <label>Currency
              <select name="currency_code" defaultValue="">
                <option value="">Customer default</option>
                {(currencies ?? []).map((c) => <option key={c.code} value={c.code}>{c.code}</option>)}
              </select>
            </label>
            <label>Customer reference<input name="customer_reference" placeholder="Customer PO number" /></label>
            <label style={{ gridColumn: "span 2" }}>Remarks<input name="remarks" /></label>
          </div>
          <p style={{ marginTop: 12 }}><button type="submit" className="primary">Create draft</button></p>
        </ActionForm>
      </div>
    </section>
  );
}
