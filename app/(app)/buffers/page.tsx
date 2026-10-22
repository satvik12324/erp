import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { fmt } from "@/lib/format";
import { ActionForm } from "@/components/ActionForm";
import { Meter, Zone, ZoneCounts, ZONE_ORDER } from "@/components/Zone";
import { addBuffer, updateBuffer } from "./actions";

type Search = Promise<{ wh?: string; zone?: string }>;

// Stock buffer board: every item held to availability, in priority order (black, red, yellow, green).
export default async function BufferBoardPage({ searchParams }: { searchParams: Search }) {
  const { wh, zone } = await searchParams;
  const { supabase, company } = await requireCompany();
  const access = await getAccess();
  await supabase.rpc("take_buffer_snapshot", { p_company_id: company.id });

  const [{ data, error }, { data: buffers }, { data: items }, { data: warehouses }, { data: events }, { data: proposals }] = await Promise.all([
    supabase.from("v_buffer_status").select("*").eq("company_id", company.id),
    supabase.from("item_buffers").select("id, item_id, warehouse_id, target_qty, is_active, items(item_code, name), warehouses(code)").eq("company_id", company.id),
    supabase.from("items").select("id, item_code, name").eq("company_id", company.id).eq("is_active", true).eq("is_template", false)
      .eq("replenishment_policy", "BUFFER").eq("item_type", "INVENTORY").order("item_code").limit(3000),
    supabase.from("warehouses").select("id, code").eq("company_id", company.id).eq("is_active", true).order("code"),
    supabase.from("buffer_events").select("item_buffer_id").eq("company_id", company.id).eq("buffer_kind", "STOCK").is("reason_code_id", null),
    supabase.from("buffer_change_proposals").select("item_buffer_id, direction, proposed_target").eq("company_id", company.id).eq("status", "PENDING"),
  ]);
  let rows = [...(data ?? [])].sort(
    (a: any, b: any) => ZONE_ORDER[a.zone] - ZONE_ORDER[b.zone] || Number(b.penetration) - Number(a.penetration),
  );
  const allZones = rows.map((r: any) => r.zone);
  if (wh) rows = rows.filter((r: any) => r.warehouse_id === wh);
  if (zone) rows = rows.filter((r: any) => r.zone === zone);
  const needsReason = new Set((events ?? []).map((e: any) => e.item_buffer_id));
  const proposal = new Map((proposals ?? []).map((p: any) => [p.item_buffer_id, p]));
  const inactive = (buffers ?? []).filter((b: any) => !b.is_active);
  const canEdit = access.full("BUFFERS");

  return (
    <section>
      <div className="page-head">
        <div>
          <h1>Buffer board</h1>
          <p className="muted">Stock buffers by penetration. Black = nothing available after orders already in their time buffer.</p>
        </div>
        <div className="spacer" />
        <Link href="/replenishment">Replenishment</Link>
        <Link href="/buffers/dbm">Buffer changes ({(proposals ?? []).length})</Link>
        <Link href="/buffers/reasons">Red/black reasons</Link>
      </div>
      <ZoneCounts zones={allZones} />
      <form className="form-row panel" method="get">
        <label>Warehouse
          <select name="wh" defaultValue={wh ?? ""}>
            <option value="">All</option>
            {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
          </select>
        </label>
        <label>Zone
          <select name="zone" defaultValue={zone ?? ""}>
            <option value="">All</option>
            {["BLACK", "RED", "YELLOW", "GREEN"].map((z) => <option key={z} value={z}>{z}</option>)}
          </select>
        </label>
        <button type="submit">Filter</button>
      </form>
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead>
          <tr>
            <th>Zone</th><th>Penetration</th><th>Item</th><th>Wh.</th><th className="num">Target</th><th className="num">On hand</th>
            <th className="num">Allocated</th><th className="num">Available</th><th className="num">On order</th><th className="num">To replenish</th><th>Unit</th><th></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r: any) => {
            const p: any = proposal.get(r.item_buffer_id);
            return (
              <tr key={r.item_buffer_id} className={`row-${r.zone}`}>
                <td><Zone zone={r.zone} /></td>
                <td><Meter pct={r.penetration} zone={r.zone} /></td>
                <td><Link href={`/items/${r.item_id}`} className="mono">{r.item_code}</Link> <span className="small">{r.item_name}</span></td>
                <td className="mono">{r.warehouse_code}</td>
                <td className="num">
                  {canEdit ? (
                    <ActionForm action={updateBuffer} resetOnSuccess={false}>
                      <input type="hidden" name="id" value={r.item_buffer_id} />
                      <input type="hidden" name="is_active" value="on" />
                      <span className="form-row" style={{ justifyContent: "flex-end", flexWrap: "nowrap" }}>
                        <input name="target_qty" type="number" step="any" min={0} defaultValue={Number(r.target_qty)} style={{ width: 80 }} />
                        <button type="submit" className="link">Set</button>
                      </span>
                    </ActionForm>
                  ) : fmt(r.target_qty)}
                </td>
                <td className="num">{fmt(r.on_hand)}</td>
                <td className="num" title={[Number(r.dependent_allocated) ? `components for orders ${fmt(r.dependent_allocated)}` : "", Number(r.spike_qty) ? `includes spike orders ${fmt(r.spike_qty)}` : ""].filter(Boolean).join("; ")}>
                  {fmt(r.allocated)}{Number(r.spike_qty) > 0 && " *"}{Number(r.dependent_allocated) > 0 && " †"}
                </td>
                <td className="num">{fmt(r.available)}</td>
                <td className="num">{fmt(r.on_order)}</td>
                <td className="num"><strong>{Number(r.replenish_qty) > 0 ? fmt(r.replenish_qty) : ""}</strong></td>
                <td className="mono small">{r.base_uom}</td>
                <td className="small">
                  {needsReason.has(r.item_buffer_id) && <Link href="/buffers/reasons" className="badge DRAFT">reason needed</Link>}{" "}
                  {p && <Link href="/buffers/dbm" className="badge">{p.direction === "INCREASE" ? "▲" : "▼"} {fmt(p.proposed_target)} proposed</Link>}
                  {canEdit && (
                    <ActionForm action={updateBuffer} resetOnSuccess={false} confirm="Stop holding a buffer for this item here?">
                      <input type="hidden" name="id" value={r.item_buffer_id} />
                      <input type="hidden" name="target_qty" value={Number(r.target_qty)} />
                      <button type="submit" className="link small">Deactivate</button>
                    </ActionForm>
                  )}
                </td>
              </tr>
            );
          })}
          {rows.length === 0 && <tr><td colSpan={12} className="empty">No stock buffers{wh || zone ? " match the filter" : ""}. Set targets below for items with replenishment policy BUFFER.</td></tr>}
        </tbody>
      </table>
      <p className="muted small">
        Allocated = open sales order quantity whose order buffer has started, plus spikes (*): single orders of at least the
        company spike % of target. It includes components needed to build ordered items that are not in stock (†), under
        the same rule; hover for the split. To replenish = target − (on hand + on order − allocated).
      </p>

      {canEdit && (
        <div className="panel" style={{ marginTop: 12 }}>
          <strong>Add a stock buffer</strong> <span className="muted small">Only items with replenishment policy BUFFER. Target in the item&apos;s base unit.</span>
          <ActionForm action={addBuffer}>
            <div className="form-row" style={{ marginTop: 8 }}>
              <label className="wide">Item
                <select name="item_id" required>
                  <option value="">—</option>
                  {(items ?? []).map((i) => <option key={i.id} value={i.id}>{i.item_code} · {i.name}</option>)}
                </select>
              </label>
              <label className="narrow">Warehouse
                <select name="warehouse_id" required>
                  {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
                </select>
              </label>
              <label className="narrow">Target<input name="target_qty" type="number" step="any" min={0} required /></label>
              <label>Note<input name="remarks" placeholder="How the target was set" /></label>
              <button type="submit" className="primary">Add</button>
            </div>
          </ActionForm>
        </div>
      )}

      {inactive.length > 0 && (
        <>
          <h2>Inactive buffers</h2>
          <table className="grid" style={{ maxWidth: 640 }}>
            <thead><tr><th>Item</th><th>Wh.</th><th className="num">Target</th><th></th></tr></thead>
            <tbody>
              {inactive.map((b: any) => (
                <tr key={b.id}>
                  <td className="mono">{b.items?.item_code} <span className="small">{b.items?.name}</span></td>
                  <td className="mono">{b.warehouses?.code}</td>
                  <td className="num">{fmt(b.target_qty)}</td>
                  <td>
                    {canEdit && (
                      <ActionForm action={updateBuffer} resetOnSuccess={false}>
                        <input type="hidden" name="id" value={b.id} />
                        <input type="hidden" name="target_qty" value={Number(b.target_qty)} />
                        <input type="hidden" name="is_active" value="on" />
                        <button type="submit" className="link">Reactivate</button>
                      </ActionForm>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </section>
  );
}
