import Link from "next/link";
import { requireCompany } from "@/lib/context";

export default async function Home() {
  const { supabase, company } = await requireCompany();

  const [items, drafts, negatives, recent, warehouses] = await Promise.all([
    supabase.from("items").select("id", { count: "exact", head: true }).eq("company_id", company.id).eq("is_active", true),
    supabase.from("inventory_documents").select("id", { count: "exact", head: true }).eq("company_id", company.id).eq("status", "DRAFT"),
    supabase.from("item_warehouse_stock").select("item_id", { count: "exact", head: true }).eq("company_id", company.id).lt("on_hand", 0),
    supabase
      .from("inventory_documents")
      .select("id, doc_number, category, doc_date, status, document_types(name)")
      .eq("company_id", company.id)
      .order("created_at", { ascending: false })
      .limit(8),
    supabase.from("warehouses").select("id", { count: "exact", head: true }).eq("company_id", company.id),
  ]);

  const setupMissing = (warehouses.count ?? 0) === 0;

  return (
    <section>
      <h1>{company.name}</h1>
      <p className="muted">
        Base currency {company.base_currency} · fiscal year starts month {company.fiscal_year_start_month}
      </p>

      {setupMissing && (
        <p className="msg err">
          This company has no warehouse yet. <Link href="/setup/warehouses">Create the main warehouse</Link> before posting stock.
        </p>
      )}

      <div className="cards">
        <Link href="/items" className="card">
          <div className="muted small">Active items</div>
          <div className="big">{items.count ?? 0}</div>
        </Link>
        <Link href="/inventory?status=DRAFT" className="card">
          <div className="muted small">Draft documents</div>
          <div className="big">{drafts.count ?? 0}</div>
        </Link>
        <Link href="/stock?neg=1" className="card">
          <div className="muted small">Items below zero</div>
          <div className="big" style={{ color: (negatives.count ?? 0) > 0 ? "var(--err)" : undefined }}>{negatives.count ?? 0}</div>
        </Link>
      </div>

      <div className="page-head">
        <h2>Recent inventory documents</h2>
        <div className="spacer" />
        <Link href="/inventory/new">New document</Link>
      </div>
      <table className="grid">
        <thead>
          <tr><th>Number</th><th>Type</th><th>Date</th><th>Status</th></tr>
        </thead>
        <tbody>
          {(recent.data ?? []).map((d: any) => (
            <tr key={d.id}>
              <td><Link href={`/inventory/${d.id}`}>{d.doc_number ?? "(draft)"}</Link></td>
              <td>{d.document_types?.name}</td>
              <td>{d.doc_date}</td>
              <td><span className={`badge ${d.status}`}>{d.status}</span></td>
            </tr>
          ))}
          {(recent.data ?? []).length === 0 && (
            <tr><td colSpan={4} className="empty">No documents yet.</td></tr>
          )}
        </tbody>
      </table>
    </section>
  );
}
