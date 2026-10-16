import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { addOption, createAttribute } from "./actions";

export default async function AttributesPage() {
  const { supabase, company } = await requireCompany();
  const { data: defs } = await supabase
    .from("attribute_definitions")
    .select("id, code, name, data_type, is_variant_axis, attribute_options(id, code, name, sort_order)")
    .eq("company_id", company.id)
    .order("sort_order")
    .order("code");

  return (
    <section>
      <h1>Attributes</h1>
      <p className="muted">
        Item characteristics such as colour or size. A LIST attribute marked as variant axis distinguishes the variants of a template item.
      </p>
      {(defs ?? []).map((d: any) => (
        <div className="panel" key={d.id}>
          <strong className="mono">{d.code}</strong> · {d.name}{" "}
          <span className="badge">{d.data_type}</span> {d.is_variant_axis && <span className="badge">variant axis</span>}
          {d.data_type === "LIST" && (
            <>
              <p className="small" style={{ marginTop: 8 }}>
                {[...d.attribute_options].sort((a: any, b: any) => a.sort_order - b.sort_order || a.code.localeCompare(b.code))
                  .map((o: any) => <span key={o.id} className="badge" style={{ marginRight: 4 }}>{o.code} · {o.name}</span>)}
                {d.attribute_options.length === 0 && <span className="muted">No options yet.</span>}
              </p>
              <ActionForm action={addOption}>
                <input type="hidden" name="attribute_definition_id" value={d.id} />
                <div className="form-row">
                  <label className="narrow">Code<input name="code" required maxLength={20} placeholder="BK" /></label>
                  <label>Name<input name="name" required placeholder="Black" /></label>
                  <label className="narrow">Order<input name="sort_order" type="number" defaultValue={0} /></label>
                  <button type="submit">Add option</button>
                </div>
              </ActionForm>
            </>
          )}
        </div>
      ))}

      <h2>New attribute</h2>
      <div className="panel">
        <ActionForm action={createAttribute}>
          <div className="form-row">
            <label className="narrow">Code<input name="code" required maxLength={20} placeholder="COLOUR" /></label>
            <label className="wide">Name<input name="name" required placeholder="Colour" /></label>
            <label className="narrow">Type
              <select name="data_type" defaultValue="LIST">
                <option value="LIST">List</option>
                <option value="TEXT">Text</option>
                <option value="NUMBER">Number</option>
              </select>
            </label>
            <label className="check"><input type="checkbox" name="is_variant_axis" />Variant axis</label>
            <button type="submit" className="primary">Create</button>
          </div>
        </ActionForm>
      </div>
    </section>
  );
}
