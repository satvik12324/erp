// Business partner master fields shared by the create and edit forms.
export function PartnerFields({ bp, currencies }: { bp?: any; currencies: { code: string; name: string }[] }) {
  return (
    <div className="form-grid">
      <label style={{ gridColumn: "span 2" }}>Name<input name="name" defaultValue={bp?.name} required /></label>
      <label>Type
        <select name="bp_type" defaultValue={bp?.bp_type ?? "SUPPLIER"}>
          <option value="SUPPLIER">Supplier</option>
          <option value="CUSTOMER">Customer</option>
          <option value="BOTH">Both</option>
        </select>
      </label>
      <label>Currency
        <select name="currency_code" defaultValue={bp?.currency_code ?? ""}>
          <option value="">Company base</option>
          {currencies.map((c) => <option key={c.code} value={c.code}>{c.code} · {c.name}</option>)}
        </select>
      </label>
      <label>Default lead time (days)<input name="default_lead_time_days" type="number" min={0} defaultValue={bp?.default_lead_time_days ?? ""} /></label>
      <label>Payment terms<input name="payment_terms" defaultValue={bp?.payment_terms ?? ""} placeholder="30 days" /></label>
      <label>Phone<input name="phone" defaultValue={bp?.phone ?? ""} /></label>
      <label>Email<input name="email" type="email" defaultValue={bp?.email ?? ""} /></label>
      <label style={{ gridColumn: "span 2" }}>Notes<input name="notes" defaultValue={bp?.notes ?? ""} /></label>
    </div>
  );
}
