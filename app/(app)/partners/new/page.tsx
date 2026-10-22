import { requireCompany } from "@/lib/context";
import { ActionForm } from "@/components/ActionForm";
import { PartnerFields } from "@/components/PartnerFields";
import { createPartner } from "../actions";

export default async function NewPartnerPage() {
  const { supabase } = await requireCompany();
  const { data: currencies } = await supabase.from("currencies").select("code, name").eq("is_active", true).order("code");
  return (
    <section>
      <h1>New business partner</h1>
      <div className="panel">
        <ActionForm action={createPartner} resetOnSuccess={false}>
          <div className="form-grid" style={{ marginBottom: 10 }}>
            <label>Code<input name="code" required maxLength={20} className="mono" placeholder="S-0001" /></label>
          </div>
          <PartnerFields currencies={currencies ?? []} />
          <p style={{ marginTop: 12 }}><button type="submit" className="primary">Create partner</button></p>
        </ActionForm>
      </div>
    </section>
  );
}
