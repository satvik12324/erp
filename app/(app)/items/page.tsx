import Link from "next/link";
import { requireCompany } from "@/lib/context";

type Search = Promise<{ q?: string; group?: string; inactive?: string }>;

export default async function ItemsPage({ searchParams }: { searchParams: Search }) {
  const { q, group, inactive } = await searchParams;
  const { supabase, company } = await requireCompany();

  let query = supabase
    .from("items")
    .select("id, item_code, name, item_type, procurement_method, replenishment_policy, is_template, template_item_id, is_active, item_groups(code), uom_groups(code)")
    .eq("company_id", company.id)
    .order("item_code")
    .limit(500);
  if (q) query = query.or(`item_code.ilike.%${q.replace(/[%,()]/g, "")}%,name.ilike.%${q.replace(/[%,()]/g, "")}%`);
  if (group) query = query.eq("item_group_id", group);
  if (!inactive) query = query.eq("is_active", true);

  const [{ data: items, error }, { data: groups }] = await Promise.all([
    query,
    supabase.from("item_groups").select("id, code, name").eq("company_id", company.id).order("code"),
  ]);

  return (
    <section>
      <div className="page-head">
        <h1>Items</h1>
        <div className="spacer" />
        <Link href="/items/new"><button className="primary">New item</button></Link>
      </div>

      <form className="form-row panel" method="get">
        <label className="wide">Search code or name<input name="q" defaultValue={q ?? ""} /></label>
        <label>Group
          <select name="group" defaultValue={group ?? ""}>
            <option value="">All groups</option>
            {(groups ?? []).map((g) => <option key={g.id} value={g.id}>{g.code} · {g.name}</option>)}
          </select>
        </label>
        <label className="check"><input type="checkbox" name="inactive" defaultChecked={!!inactive} />Include inactive</label>
        <button type="submit">Filter</button>
      </form>

      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead>
          <tr><th>Code</th><th>Name</th><th>Group</th><th>Type</th><th>Procure</th><th>Replenish</th><th>UoM group</th><th></th></tr>
        </thead>
        <tbody>
          {(items ?? []).map((i: any) => (
            <tr key={i.id}>
              <td className="mono"><Link href={`/items/${i.id}`}>{i.item_code}</Link></td>
              <td>{i.name}</td>
              <td className="mono">{i.item_groups?.code}</td>
              <td className="small">{i.item_type}</td>
              <td className="small">{i.procurement_method}</td>
              <td className="small">{i.replenishment_policy}</td>
              <td className="mono small">{i.uom_groups?.code}</td>
              <td>
                {i.is_template && <span className="badge">template</span>}{" "}
                {i.template_item_id && <span className="badge">variant</span>}{" "}
                {!i.is_active && <span className="badge off">inactive</span>}
              </td>
            </tr>
          ))}
          {(items ?? []).length === 0 && <tr><td colSpan={8} className="empty">No items match.</td></tr>}
        </tbody>
      </table>
      {(items ?? []).length === 500 && <p className="muted small">Showing the first 500. Narrow the search.</p>}
    </section>
  );
}
