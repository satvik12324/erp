import Link from "next/link";
import { notFound } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { ItemFields } from "@/components/ItemFields";
import { addBomLine, createBom, createVariant, deleteBomLine, setAttribute, updateItem } from "../actions";
import { getAccess } from "@/lib/access";
import { ItemSupplierSection } from "@/components/ItemSupplierSection";

const fmt = (n: number | string) => Number(n).toLocaleString("en-IN", { maximumFractionDigits: 6 });

export default async function ItemPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, company } = await requireCompany();

  const { data: item } = await supabase
    .from("items")
    .select("*, item_groups(code, name), uom_groups(code, base_uom_id)")
    .eq("id", id)
    .eq("company_id", company.id)
    .maybeSingle();
  if (!item) notFound();

  const [
    { data: uoms }, { data: warehouses }, { data: defs }, { data: values }, { data: variants },
    { data: bom }, { data: components }, { data: stock }, { data: explosion }, { data: usedIn },
  ] = await Promise.all([
    supabase.from("uoms").select("id, code").eq("company_id", company.id).order("code"),
    supabase.from("warehouses").select("id, code, name").eq("company_id", company.id).eq("is_active", true).order("code"),
    supabase.from("attribute_definitions").select("id, code, name, data_type, is_variant_axis, attribute_options(id, code, name, sort_order)")
      .eq("company_id", company.id).eq("is_active", true).order("sort_order").order("code"),
    supabase.from("item_attribute_values").select("attribute_definition_id, option_id, text_value, number_value").eq("item_id", id),
    item.is_template
      ? supabase.from("items").select("id, item_code, name, is_active, item_attribute_values(attribute_definition_id, option_id)").eq("template_item_id", id).order("item_code")
      : Promise.resolve({ data: [] as any[] }),
    supabase.from("bom_headers").select("id, base_quantity, uom_id, bom_lines(id, line_no, component_item_id, quantity, uom_id, issue_method, issue_warehouse_id)")
      .eq("item_id", id).eq("is_active", true).maybeSingle(),
    supabase.from("items").select("id, item_code, name").eq("company_id", company.id).eq("is_template", false).eq("is_active", true).neq("id", id).order("item_code").limit(2000),
    supabase.from("v_stock_on_hand").select("warehouse_id, warehouse_code, on_hand, base_uom").eq("item_id", id).order("warehouse_code"),
    item.is_template ? Promise.resolve({ data: [] as any[] }) : supabase.rpc("bom_explosion", { p_item_id: id }),
    supabase.from("bom_lines").select("bom_headers!inner(item_id, is_active, items!inner(id, item_code, name))").eq("component_item_id", id).eq("bom_headers.is_active", true),
  ]);
  const access = await getAccess();
  const [{ data: itemSuppliers }, { data: suppliers }, { data: leadStats }, { data: onOrder }] = await Promise.all([
    supabase.from("item_suppliers").select("*, business_partners(code, name)").eq("item_id", id).order("is_preferred", { ascending: false }),
    supabase.from("business_partners").select("id, code, name").eq("company_id", company.id).eq("is_active", true).in("bp_type", ["SUPPLIER", "BOTH"]).order("code"),
    supabase.from("v_item_supplier_lead_time").select("*").eq("item_id", id),
    supabase.from("v_on_order").select("warehouse_id, on_order").eq("item_id", id),
  ]);
  const onOrderByWh = new Map((onOrder ?? []).map((o: any) => [o.warehouse_id, Number(o.on_order)]));
  const totalOnOrder = (onOrder ?? []).reduce((s: number, o: any) => s + Number(o.on_order), 0);

  const uomCode = new Map((uoms ?? []).map((u) => [u.id, u.code]));
  const whCode = new Map((warehouses ?? []).map((w) => [w.id, w.code]));
  const comp = new Map((components ?? []).map((c) => [c.id, c]));
  const valueOf = new Map((values ?? []).map((v) => [v.attribute_definition_id, v]));
  const axes = (defs ?? []).filter((d: any) => d.is_variant_axis);
  const optName = new Map<string, string>((defs ?? []).flatMap((d: any) => d.attribute_options.map((o: any) => [o.id, o.code] as [string, string])));

  return (
    <section>
      <div className="page-head">
        <div>
          <p className="muted small"><Link href="/items">Items</Link> / {item.item_groups?.code}</p>
          <h1><span className="mono">{item.item_code}</span> · {item.name}</h1>
          <p className="muted small">
            UoM group {item.uom_groups?.code}
            {item.is_template && <> · <span className="badge">template</span></>}
            {item.template_item_id && <> · variant of <Link href={`/items/${item.template_item_id}`}>template</Link></>}
            {!item.is_active && <> · <span className="badge off">inactive</span></>}
          </p>
        </div>
      </div>

      <div className="panel">
        <ActionForm action={updateItem} resetOnSuccess={false}>
          <input type="hidden" name="id" value={item.id} />
          <ItemFields item={item} uoms={uoms ?? []} warehouses={warehouses ?? []} />
          <div className="form-row" style={{ marginTop: 10 }}>
            <label className="check"><input type="checkbox" name="is_active" defaultChecked={item.is_active} />Active</label>
            <button type="submit" className="primary">Save item</button>
          </div>
        </ActionForm>
      </div>

      {(stock ?? []).length === 0 && totalOnOrder > 0 && (
        <p className="muted">No stock yet · {fmt(totalOnOrder)} on order.</p>
      )}
      {(stock ?? []).length > 0 && (
        <>
          <h2>Stock</h2>
          <table className="grid" style={{ maxWidth: 520 }}>
            <thead><tr><th>Warehouse</th><th className="num">On hand</th><th className="num">On order</th></tr></thead>
            <tbody>
              {(stock ?? []).map((s: any) => (
                <tr key={s.warehouse_code}>
                  <td className="mono">{s.warehouse_code}</td>
                  <td className={`num ${Number(s.on_hand) < 0 ? "badge neg" : ""}`}>{fmt(s.on_hand)} {s.base_uom}</td>
                  <td className="num">{onOrderByWh.get(s.warehouse_id) ? fmt(onOrderByWh.get(s.warehouse_id)!) : ""}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}

      {item.is_purchased && !item.is_template && (
        <>
          <h2>Suppliers</h2>
          <ItemSupplierSection mode="item" fixedId={item.id} rows={itemSuppliers ?? []} options={suppliers ?? []} uoms={uoms ?? []}
            stats={new Map((leadStats ?? []).map((l: any) => [l.business_partner_id, l]))} canEdit={access.full("PURCHASING")} />
        </>
      )}

      <h2>Attributes</h2>
      {(defs ?? []).length === 0 && <p className="muted">No attributes defined. <Link href="/setup/attributes">Define attributes</Link>.</p>}
      <table className="grid">
        <tbody>
          {(defs ?? []).map((d: any) => {
            const v: any = valueOf.get(d.id);
            const current = v ? (v.option_id ?? v.text_value ?? v.number_value ?? "") : "";
            return (
              <tr key={d.id}>
                <td style={{ width: 200 }}>{d.name} <span className="muted small">{d.is_variant_axis ? "(variant axis)" : ""}</span></td>
                <td>
                  <ActionForm action={setAttribute} resetOnSuccess={false}>
                    <input type="hidden" name="item_id" value={item.id} />
                    <input type="hidden" name="attribute_definition_id" value={d.id} />
                    <input type="hidden" name="data_type" value={d.data_type} />
                    <div className="form-row">
                      {d.data_type === "LIST" ? (
                        <select name="value" defaultValue={String(current)}>
                          <option value="">—</option>
                          {d.attribute_options.map((o: any) => <option key={o.id} value={o.id}>{o.code} · {o.name}</option>)}
                        </select>
                      ) : (
                        <input name="value" type={d.data_type === "NUMBER" ? "number" : "text"} step="any" defaultValue={String(current)} />
                      )}
                      <button type="submit">Set</button>
                    </div>
                  </ActionForm>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      {item.is_template && (
        <>
          <h2>Variants</h2>
          <table className="grid">
            <thead><tr><th>Code</th><th>Name</th>{axes.map((a: any) => <th key={a.id}>{a.name}</th>)}</tr></thead>
            <tbody>
              {(variants ?? []).map((v: any) => (
                <tr key={v.id}>
                  <td className="mono"><Link href={`/items/${v.id}`}>{v.item_code}</Link></td>
                  <td>{v.name} {!v.is_active && <span className="badge off">inactive</span>}</td>
                  {axes.map((a: any) => {
                    const av = v.item_attribute_values.find((x: any) => x.attribute_definition_id === a.id);
                    return <td key={a.id} className="mono">{av ? optName.get(av.option_id) : "—"}</td>;
                  })}
                </tr>
              ))}
              {(variants ?? []).length === 0 && <tr><td colSpan={2 + axes.length} className="empty">No variants yet.</td></tr>}
            </tbody>
          </table>
          <div className="panel" style={{ marginTop: 10 }}>
            <strong>New variant</strong>
            <ActionForm action={createVariant}>
              <input type="hidden" name="template_item_id" value={item.id} />
              <div className="form-row" style={{ marginTop: 8 }}>
                <label>Code<input name="item_code" className="mono" placeholder="auto from group series" /></label>
                <label className="wide">Name<input name="name" placeholder={item.name} /></label>
                {axes.map((a: any) => (
                  <label key={a.id}>{a.name}
                    <select name={`axis:${a.id}`} required>
                      <option value="">—</option>
                      {a.attribute_options.map((o: any) => <option key={o.id} value={o.id}>{o.code} · {o.name}</option>)}
                    </select>
                  </label>
                ))}
                <button type="submit" className="primary">Create variant</button>
              </div>
              {axes.length === 0 && <p className="muted small">Mark at least one LIST attribute as variant axis first.</p>}
            </ActionForm>
          </div>
        </>
      )}

      {!item.is_template && (
        <>
          <h2>Bill of materials</h2>
          {!bom ? (
            <div className="panel">
              <p className="muted">No BOM yet.</p>
              <ActionForm action={createBom}>
                <input type="hidden" name="item_id" value={item.id} />
                <div className="form-row">
                  <label className="narrow">Quantities per<input name="base_quantity" type="number" step="any" min={0} defaultValue={1} required /></label>
                  <label className="narrow">UoM
                    <select name="uom_id" defaultValue={item.inventory_uom_id}>
                      {(uoms ?? []).map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                    </select>
                  </label>
                  <button type="submit" className="primary">Create BOM</button>
                </div>
              </ActionForm>
            </div>
          ) : (
            <>
              <p className="muted small">Component quantities are per {fmt(bom.base_quantity)} {uomCode.get(bom.uom_id)} of {item.item_code}.</p>
              <table className="grid">
                <thead>
                  <tr><th className="num">Line</th><th>Component</th><th className="num">Qty</th><th>UoM</th><th>Issue</th><th>From warehouse</th><th></th></tr>
                </thead>
                <tbody>
                  {[...bom.bom_lines].sort((a: any, b: any) => a.line_no - b.line_no).map((l: any) => {
                    const c: any = comp.get(l.component_item_id);
                    return (
                      <tr key={l.id}>
                        <td className="num">{l.line_no}</td>
                        <td><Link href={`/items/${l.component_item_id}`} className="mono">{c?.item_code ?? "?"}</Link> {c?.name}</td>
                        <td className="num">{fmt(l.quantity)}</td>
                        <td className="mono">{uomCode.get(l.uom_id)}</td>
                        <td className="small">{l.issue_method}</td>
                        <td className="mono small">{l.issue_warehouse_id ? whCode.get(l.issue_warehouse_id) : <span className="muted">default</span>}</td>
                        <td className="num">
                          <ActionForm action={deleteBomLine} confirm="Remove this component?">
                            <input type="hidden" name="id" value={l.id} />
                            <input type="hidden" name="item_id" value={item.id} />
                            <button type="submit" className="link">Remove</button>
                          </ActionForm>
                        </td>
                      </tr>
                    );
                  })}
                  {bom.bom_lines.length === 0 && <tr><td colSpan={7} className="empty">No components yet.</td></tr>}
                </tbody>
              </table>
              <div className="panel" style={{ marginTop: 10 }}>
                <ActionForm action={addBomLine}>
                  <input type="hidden" name="bom_id" value={bom.id} />
                  <input type="hidden" name="item_id" value={item.id} />
                  <div className="form-row">
                    <label className="wide">Component
                      <select name="component_item_id" required>
                        <option value="">—</option>
                        {(components ?? []).map((c) => <option key={c.id} value={c.id}>{c.item_code} · {c.name}</option>)}
                      </select>
                    </label>
                    <label className="narrow">Qty<input name="quantity" type="number" step="any" min={0} required /></label>
                    <label className="narrow">UoM
                      <select name="uom_id" defaultValue="">
                        <option value="">Item&apos;s</option>
                        {(uoms ?? []).map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                      </select>
                    </label>
                    <label className="narrow">Issue
                      <select name="issue_method" defaultValue="BACKFLUSH">
                        <option value="BACKFLUSH">Backflush</option>
                        <option value="MANUAL">Manual</option>
                      </select>
                    </label>
                    <label className="narrow">From warehouse
                      <select name="issue_warehouse_id" defaultValue="">
                        <option value="">Default</option>
                        {(warehouses ?? []).map((w) => <option key={w.id} value={w.id}>{w.code}</option>)}
                      </select>
                    </label>
                    <button type="submit" className="primary">Add component</button>
                  </div>
                </ActionForm>
              </div>

              {(explosion ?? []).some((e: any) => e.level > 1) && (
                <>
                  <h2>Exploded BOM (all levels, per 1 {item.uom_groups ? uomCode.get(item.uom_groups.base_uom_id) : ""})</h2>
                  <table className="grid">
                    <thead><tr><th className="num">Level</th><th>Path</th><th>Component</th><th className="num">Qty</th><th>Issue</th></tr></thead>
                    <tbody>
                      {(explosion ?? []).map((e: any, i: number) => (
                        <tr key={i}>
                          <td className="num">{e.level}</td>
                          <td className="small muted">{e.path}</td>
                          <td className="mono">{e.item_code}</td>
                          <td className="num">{fmt(e.qty_per_parent)} {e.base_uom_code}</td>
                          <td className="small">{e.issue_method}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </>
              )}
            </>
          )}
        </>
      )}

      {(usedIn ?? []).length > 0 && (
        <>
          <h2>Used in</h2>
          <p>
            {(usedIn ?? []).map((u: any) => (
              <Link key={u.bom_headers.items.id} href={`/items/${u.bom_headers.items.id}`} className="mono" style={{ marginRight: 12 }}>
                {u.bom_headers.items.item_code}
              </Link>
            ))}
          </p>
        </>
      )}
    </section>
  );
}
