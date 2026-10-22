import Link from "next/link";
import { notFound } from "next/navigation";
import { requireCompany } from "@/lib/context";
import { getAccess } from "@/lib/access";
import { ActionForm } from "@/components/ActionForm";
import { PartnerFields } from "@/components/PartnerFields";
import { ItemSupplierSection } from "@/components/ItemSupplierSection";
import { addAddress, addContact, addRegistration, deleteChild, updatePartner } from "../actions";

export default async function PartnerPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, company } = await requireCompany();
  const access = await getAccess();

  const { data: bp } = await supabase.from("business_partners").select("*").eq("id", id).eq("company_id", company.id).maybeSingle();
  if (!bp) notFound();
  const isSupplier = bp.bp_type !== "CUSTOMER";
  const canEdit = access.full("BUSINESS_PARTNERS");

  const [{ data: currencies }, { data: addresses }, { data: contacts }, { data: regs }, { data: links }, { data: items }, { data: uoms }, { data: stats }, { data: pos }] =
    await Promise.all([
      supabase.from("currencies").select("code, name").eq("is_active", true).order("code"),
      supabase.from("bp_addresses").select("*").eq("business_partner_id", id).order("address_type"),
      supabase.from("bp_contacts").select("*").eq("business_partner_id", id).order("name"),
      supabase.from("bp_registrations").select("*").eq("business_partner_id", id).order("registration_type"),
      isSupplier
        ? supabase.from("item_suppliers").select("*, items(item_code, name)").eq("business_partner_id", id).order("created_at")
        : Promise.resolve({ data: [] as any[] }),
      isSupplier
        ? supabase.from("items").select("id, item_code, name").eq("company_id", company.id).eq("is_active", true).eq("is_template", false).order("item_code").limit(3000)
        : Promise.resolve({ data: [] as any[] }),
      supabase.from("uoms").select("id, code").eq("company_id", company.id).order("code"),
      isSupplier ? supabase.from("v_item_supplier_lead_time").select("*").eq("business_partner_id", id) : Promise.resolve({ data: [] as any[] }),
      isSupplier
        ? supabase.from("purchase_orders").select("id, doc_number, doc_date, status").eq("business_partner_id", id).order("doc_date", { ascending: false }).limit(20)
        : Promise.resolve({ data: [] as any[] }),
    ]);

  const statsByItem = new Map((stats ?? []).map((s: any) => [s.item_id, s]));

  return (
    <section>
      <p className="muted small"><Link href="/partners">Business partners</Link></p>
      <h1><span className="mono">{bp.code}</span> · {bp.name}</h1>

      <div className="panel">
        <ActionForm action={updatePartner} resetOnSuccess={false}>
          <input type="hidden" name="id" value={bp.id} />
          <PartnerFields bp={bp} currencies={currencies ?? []} />
          <div className="form-row" style={{ marginTop: 10 }}>
            <label className="check"><input type="checkbox" name="is_active" defaultChecked={bp.is_active} />Active</label>
            {canEdit && <button type="submit" className="primary">Save</button>}
          </div>
        </ActionForm>
      </div>

      {isSupplier && (
        <>
          <div className="page-head">
            <h2>Items supplied</h2>
            <div className="spacer" />
            {access.full("PURCHASING") && <Link href={`/purchasing/new?bp=${bp.id}`}>New purchase order</Link>}
          </div>
          <ItemSupplierSection mode="partner" fixedId={bp.id} rows={links ?? []} options={items ?? []} uoms={uoms ?? []}
            stats={statsByItem} canEdit={access.full("PURCHASING")} />

          <h2>Recent purchase orders</h2>
          <table className="grid">
            <thead><tr><th>Number</th><th>Date</th><th>Status</th></tr></thead>
            <tbody>
              {(pos ?? []).map((p: any) => (
                <tr key={p.id}>
                  <td className="mono"><Link href={`/purchasing/${p.id}`}>{p.doc_number ?? "(draft)"}</Link></td>
                  <td>{p.doc_date}</td>
                  <td><span className={`badge ${p.status === "OPEN" ? "POSTED" : p.status}`}>{p.status}</span></td>
                </tr>
              ))}
              {(pos ?? []).length === 0 && <tr><td colSpan={3} className="empty">No purchase orders.</td></tr>}
            </tbody>
          </table>
        </>
      )}

      <h2>Tax and trade IDs</h2>
      <table className="grid" style={{ maxWidth: 640 }}>
        <tbody>
          {(regs ?? []).map((r: any) => (
            <tr key={r.id}>
              <td className="mono">{r.registration_type}</td><td className="mono">{r.registration_number}</td>
              <td className="num">{canEdit && <DeleteChild table="bp_registrations" id={r.id} bp={bp.id} />}</td>
            </tr>
          ))}
          {(regs ?? []).length === 0 && <tr><td className="empty">None.</td></tr>}
        </tbody>
      </table>
      {canEdit && (
        <ActionForm action={addRegistration}>
          <input type="hidden" name="business_partner_id" value={bp.id} />
          <div className="form-row" style={{ marginTop: 8, maxWidth: 640 }}>
            <label className="narrow">Type<input name="registration_type" required placeholder="GSTIN" /></label>
            <label>Number<input name="registration_number" required /></label>
            <button type="submit">Add</button>
          </div>
        </ActionForm>
      )}

      <h2>Addresses</h2>
      <table className="grid">
        <tbody>
          {(addresses ?? []).map((a: any) => (
            <tr key={a.id}>
              <td className="small">{a.address_type}{a.is_default && " · default"}</td>
              <td><strong>{a.label}</strong> — {[a.line1, a.line2, a.city, a.region, a.postal_code, a.country_code].filter(Boolean).join(", ")}</td>
              <td className="num">{canEdit && <DeleteChild table="bp_addresses" id={a.id} bp={bp.id} />}</td>
            </tr>
          ))}
          {(addresses ?? []).length === 0 && <tr><td className="empty">None.</td></tr>}
        </tbody>
      </table>
      {canEdit && (
        <div className="panel" style={{ marginTop: 8 }}>
          <ActionForm action={addAddress}>
            <input type="hidden" name="business_partner_id" value={bp.id} />
            <div className="form-row">
              <label className="narrow">Type
                <select name="address_type"><option value="BILL_TO">Bill to</option><option value="SHIP_TO">Ship to</option></select>
              </label>
              <label>Label<input name="label" required placeholder="Head office" /></label>
              <label className="wide">Line 1<input name="line1" /></label>
              <label>Line 2<input name="line2" /></label>
              <label>City<input name="city" /></label>
              <label className="narrow">Region<input name="region" /></label>
              <label className="narrow">Postal code<input name="postal_code" /></label>
              <label className="narrow">Country<input name="country_code" maxLength={2} placeholder="IN" /></label>
              <label className="check"><input type="checkbox" name="is_default" />Default</label>
              <button type="submit">Add</button>
            </div>
          </ActionForm>
        </div>
      )}

      <h2>Contacts</h2>
      <table className="grid">
        <tbody>
          {(contacts ?? []).map((c: any) => (
            <tr key={c.id}>
              <td><strong>{c.name}</strong> {c.is_primary && <span className="badge">primary</span>}</td>
              <td className="small">{c.role}</td><td className="small">{c.phone}</td><td className="small">{c.email}</td>
              <td className="num">{canEdit && <DeleteChild table="bp_contacts" id={c.id} bp={bp.id} />}</td>
            </tr>
          ))}
          {(contacts ?? []).length === 0 && <tr><td className="empty">None.</td></tr>}
        </tbody>
      </table>
      {canEdit && (
        <ActionForm action={addContact}>
          <input type="hidden" name="business_partner_id" value={bp.id} />
          <div className="form-row" style={{ marginTop: 8 }}>
            <label>Name<input name="name" required /></label>
            <label>Role<input name="role" /></label>
            <label>Phone<input name="phone" /></label>
            <label>Email<input name="email" type="email" /></label>
            <label className="check"><input type="checkbox" name="is_primary" />Primary</label>
            <button type="submit">Add</button>
          </div>
        </ActionForm>
      )}
    </section>
  );
}

function DeleteChild({ table, id, bp }: { table: string; id: string; bp: string }) {
  return (
    <ActionForm action={deleteChild} confirm="Remove?">
      <input type="hidden" name="table" value={table} />
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="business_partner_id" value={bp} />
      <button type="submit" className="link">Remove</button>
    </ActionForm>
  );
}
