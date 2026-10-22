import Link from "next/link";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { ActionForm } from "@/components/ActionForm";
import { Zone } from "@/components/Zone";
import { setEventReason } from "../actions";

type Search = Promise<{ days?: string }>;

// Every entry of a buffer into red or black, with the cause recorded by the user, and a Pareto of causes.
export default async function BufferReasonsPage({ searchParams }: { searchParams: Search }) {
  const { days } = await searchParams;
  const window = Number(days ?? 90) || 90;
  const { supabase, company } = await requireCompany();
  const access = await getAccess();
  const since = new Date(Date.now() - window * 86400000).toISOString().slice(0, 10);

  const [{ data: events, error }, { data: reasons }] = await Promise.all([
    supabase.from("buffer_events")
      .select("id, buffer_kind, zone, entered_on, penetration, reason_code_id, reason_note, item_buffer_id, sales_order_id, item_buffers(items(item_code, name), warehouses(code)), sales_orders(doc_number, business_partners(code)), reason_codes(code, name)")
      .eq("company_id", company.id).gte("entered_on", since)
      .order("entered_on", { ascending: false }).limit(1000),
    supabase.from("reason_codes").select("id, reason_type, code, name").eq("company_id", company.id).eq("is_active", true)
      .in("reason_type", ["BUFFER_RED", "BUFFER_BLACK"]).order("code"),
  ]);
  const open = (events ?? []).filter((e: any) => !e.reason_code_id);
  const done = (events ?? []).filter((e: any) => e.reason_code_id);
  const canSet = access.full("BUFFERS") || access.full("SALES") || access.full("INVENTORY");

  // Pareto over the window, by reason name across red and black.
  const counts = new Map<string, number>();
  for (const e of events ?? []) {
    const k = (e as any).reason_codes?.name ?? "No reason given";
    counts.set(k, (counts.get(k) ?? 0) + 1);
  }
  const pareto = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  const totalEvents = (events ?? []).length;
  let cum = 0;

  const label = (e: any) =>
    e.buffer_kind === "STOCK" ? (
      <><span className="mono">{e.item_buffers?.items?.item_code}</span> <span className="small">{e.item_buffers?.items?.name} · {e.item_buffers?.warehouses?.code}</span></>
    ) : (
      <>Order <Link href={`/sales/${e.sales_order_id}`} className="mono">{e.sales_orders?.doc_number}</Link> <span className="small">{e.sales_orders?.business_partners?.code}</span></>
    );

  return (
    <section>
      <div className="page-head">
        <div>
          <h1>Red and black buffers: causes</h1>
          <p className="muted">Each time a stock or order buffer enters red or black, record why. The Pareto shows which causes to remove first.</p>
        </div>
        <div className="spacer" />
        <form method="get" className="form-row">
          <label className="narrow">Last days<input name="days" type="number" min={1} defaultValue={window} /></label>
          <button type="submit">Show</button>
        </form>
      </div>
      {error && <p className="msg err">{error.message}</p>}

      <h2>Waiting for a reason ({open.length})</h2>
      <table className="grid">
        <thead><tr><th>Entered</th><th>Zone</th><th>Buffer</th><th className="num">Penetration</th><th>Reason</th></tr></thead>
        <tbody>
          {open.map((e: any) => {
            const type = e.zone === "RED" ? "BUFFER_RED" : "BUFFER_BLACK";
            const options = (reasons ?? []).filter((r) => r.reason_type === type);
            return (
              <tr key={e.id} className={`row-${e.zone}`}>
                <td>{e.entered_on}</td>
                <td><Zone zone={e.zone} /></td>
                <td>{label(e)}</td>
                <td className="num">{e.penetration}%</td>
                <td>
                  {canSet && options.length > 0 ? (
                    <ActionForm action={setEventReason}>
                      <input type="hidden" name="event_id" value={e.id} />
                      <div className="form-row">
                        <select name="reason_id" required>
                          <option value="">—</option>
                          {options.map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                        </select>
                        <input name="note" placeholder="Detail (optional)" />
                        <button type="submit">Record</button>
                      </div>
                    </ActionForm>
                  ) : options.length === 0 ? (
                    <span className="muted small">Add reasons of type &quot;{type === "BUFFER_RED" ? "Buffer entered red" : "Buffer entered black / late"}&quot; under <Link href="/setup/reasons">Reason codes</Link>.</span>
                  ) : null}
                </td>
              </tr>
            );
          })}
          {open.length === 0 && <tr><td colSpan={5} className="empty">Nothing waiting.</td></tr>}
        </tbody>
      </table>

      <h2>Pareto of causes, last {window} days</h2>
      <table className="grid" style={{ maxWidth: 720 }}>
        <thead><tr><th>Cause</th><th className="num">Events</th><th className="num">%</th><th className="num">Cumulative %</th><th></th></tr></thead>
        <tbody>
          {pareto.map(([name, n]) => {
            cum += n;
            const pct = Math.round((n * 100) / totalEvents);
            return (
              <tr key={name}>
                <td>{name}</td>
                <td className="num">{n}</td>
                <td className="num">{pct}</td>
                <td className="num">{Math.round((cum * 100) / totalEvents)}</td>
                <td><span className="meter"><span className="RED" style={{ width: `${pct}%` }} /></span></td>
              </tr>
            );
          })}
          {pareto.length === 0 && <tr><td colSpan={5} className="empty">No red or black entries in this period.</td></tr>}
        </tbody>
      </table>

      <h2>Recorded</h2>
      <table className="grid">
        <thead><tr><th>Entered</th><th>Zone</th><th>Buffer</th><th>Cause</th><th>Detail</th></tr></thead>
        <tbody>
          {done.map((e: any) => (
            <tr key={e.id}>
              <td>{e.entered_on}</td>
              <td><Zone zone={e.zone} /></td>
              <td>{label(e)}</td>
              <td>{e.reason_codes?.code} · {e.reason_codes?.name}</td>
              <td className="small">{e.reason_note}</td>
            </tr>
          ))}
          {done.length === 0 && <tr><td colSpan={5} className="empty">None yet.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
