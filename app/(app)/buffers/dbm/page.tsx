import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { fmt } from "@/lib/format";
import { ActionForm } from "@/components/ActionForm";
import { decideChange } from "../actions";

// Dynamic Buffer Management: proposals from the daily snapshots. Nothing changes until a user approves.
export default async function DbmPage() {
  const { supabase, company } = await requireCompany();
  const access = await getAccess();
  const [{ data: pending, error }, { data: history }, { data: settings }] = await Promise.all([
    supabase.from("buffer_change_proposals")
      .select("id, proposed_on, direction, current_target, proposed_target, basis, item_buffers(target_qty, items(id, item_code, name), warehouses(code))")
      .eq("company_id", company.id).eq("status", "PENDING").order("proposed_on"),
    supabase.from("buffer_change_proposals")
      .select("id, proposed_on, direction, current_target, proposed_target, approved_target, status, decided_at, decision_note, item_buffers(items(item_code), warehouses(code))")
      .eq("company_id", company.id).neq("status", "PENDING").order("created_at", { ascending: false }).limit(100),
    supabase.from("company_settings").select("dbm_red_days, dbm_green_days, dbm_step_pct").eq("company_id", company.id).maybeSingle(),
  ]);
  const canDecide = access.full("BUFFERS");

  return (
    <section>
      <p className="muted small"><Link href="/buffers">Buffer board</Link></p>
      <h1>Buffer changes (DBM)</h1>
      <p className="muted">
        Increase proposed after {settings?.dbm_red_days ?? 7} consecutive days in red or black; decrease after{" "}
        {settings?.dbm_green_days ?? 30} days in green; step {settings?.dbm_step_pct ?? 33}%. Change these under{" "}
        <Link href="/setup/company">Company</Link>. Targets change only when you approve.
      </p>
      {error && <p className="msg err">{error.message}</p>}
      <table className="grid">
        <thead><tr><th>Proposed</th><th>Item</th><th>Wh.</th><th>Change</th><th>Why</th><th>Decision</th></tr></thead>
        <tbody>
          {(pending ?? []).map((p: any) => (
            <tr key={p.id}>
              <td>{p.proposed_on}</td>
              <td><Link href={`/items/${p.item_buffers?.items?.id}`} className="mono">{p.item_buffers?.items?.item_code}</Link> <span className="small">{p.item_buffers?.items?.name}</span></td>
              <td className="mono">{p.item_buffers?.warehouses?.code}</td>
              <td><strong>{p.direction === "INCREASE" ? "▲" : "▼"}</strong> {fmt(p.current_target)} → {fmt(p.proposed_target)}</td>
              <td className="small">{p.basis}</td>
              <td>
                {canDecide ? (
                  <div className="form-row">
                    <ActionForm action={decideChange} resetOnSuccess={false}>
                      <input type="hidden" name="proposal_id" value={p.id} />
                      <input type="hidden" name="decision" value="approve" />
                      <span className="form-row" style={{ flexWrap: "nowrap" }}>
                        <input name="target" type="number" step="any" min={0} defaultValue={Number(p.proposed_target)} style={{ width: 90 }} />
                        <button type="submit" className="primary">Approve</button>
                      </span>
                    </ActionForm>
                    <ActionForm action={decideChange} resetOnSuccess={false}>
                      <input type="hidden" name="proposal_id" value={p.id} />
                      <input type="hidden" name="decision" value="reject" />
                      <span className="form-row" style={{ flexWrap: "nowrap" }}>
                        <input name="note" placeholder="Why not (optional)" />
                        <button type="submit">Reject</button>
                      </span>
                    </ActionForm>
                  </div>
                ) : <span className="muted small">Needs Buffers = Full</span>}
              </td>
            </tr>
          ))}
          {(pending ?? []).length === 0 && <tr><td colSpan={6} className="empty">No pending proposals.</td></tr>}
        </tbody>
      </table>

      <h2>History</h2>
      <table className="grid">
        <thead><tr><th>Proposed</th><th>Item</th><th>Wh.</th><th>Change</th><th>Status</th><th>Note</th></tr></thead>
        <tbody>
          {(history ?? []).map((p: any) => (
            <tr key={p.id}>
              <td>{p.proposed_on}</td>
              <td className="mono">{p.item_buffers?.items?.item_code}</td>
              <td className="mono">{p.item_buffers?.warehouses?.code}</td>
              <td>{fmt(p.current_target)} → {fmt(p.approved_target ?? p.proposed_target)}</td>
              <td><span className={`badge ${p.status === "APPROVED" ? "POSTED" : "off"}`}>{p.status}</span></td>
              <td className="small">{p.decision_note}</td>
            </tr>
          ))}
          {(history ?? []).length === 0 && <tr><td colSpan={6} className="empty">No decisions yet.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
