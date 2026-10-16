import Link from "next/link";
import { requireCompany } from "@/lib/context";

type Search = Promise<{ status?: string; type?: string }>;

export default async function InventoryDocsPage({ searchParams }: { searchParams: Search }) {
  const { status, type } = await searchParams;
  const { supabase, company } = await requireCompany();

  let q = supabase
    .from("inventory_documents")
    .select("id, doc_number, doc_date, status, reference, remarks, created_at, document_types(code, name), inventory_document_lines(count)")
    .eq("company_id", company.id)
    .order("doc_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(300);
  if (status) q = q.eq("status", status);
  if (type) q = q.eq("document_type_id", type);

  const [{ data: docs, error }, { data: types }] = await Promise.all([
    q,
    supabase.from("document_types").select("id, code, name").eq("company_id", company.id)
      .in("category", ["GOODS_RECEIPT", "GOODS_ISSUE", "INVENTORY_TRANSFER", "RECEIPT_FROM_PRODUCTION"]).order("code"),
  ]);

  return (
    <section>
      <div className="page-head">
        <h1>Inventory documents</h1>
        <div className="spacer" />
        <Link href="/inventory/new"><button className="primary">New document</button></Link>
      </div>
      <form className="form-row panel" method="get">
        <label>Type
          <select name="type" defaultValue={type ?? ""}>
            <option value="">All</option>
            {(types ?? []).map((t) => <option key={t.id} value={t.id}>{t.code} · {t.name}</option>)}
          </select>
        </label>
        <label>Status
          <select name="status" defaultValue={status ?? ""}>
            <option value="">All</option>
            <option value="DRAFT">Draft</option>
            <option value="POSTED">Posted</option>
            <option value="CANCELLED">Cancelled</option>
          </select>
        </label>
        <button type="submit">Filter</button>
      </form>
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead><tr><th>Number</th><th>Type</th><th>Date</th><th className="num">Lines</th><th>Reference / remarks</th><th>Status</th></tr></thead>
        <tbody>
          {(docs ?? []).map((d: any) => (
            <tr key={d.id}>
              <td className="mono"><Link href={`/inventory/${d.id}`}>{d.doc_number ?? "(draft)"}</Link></td>
              <td>{d.document_types?.name}</td>
              <td>{d.doc_date}</td>
              <td className="num">{d.inventory_document_lines?.[0]?.count ?? 0}</td>
              <td className="small">{[d.reference, d.remarks].filter(Boolean).join(" · ")}</td>
              <td><span className={`badge ${d.status}`}>{d.status}</span></td>
            </tr>
          ))}
          {(docs ?? []).length === 0 && <tr><td colSpan={6} className="empty">No documents.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
