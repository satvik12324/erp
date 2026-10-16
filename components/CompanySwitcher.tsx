"use client";

import { switchCompany } from "@/app/(app)/company-actions";

type Props = { companies: { id: string; code: string; name: string }[]; current: string | null };

// Changing the selection submits immediately; every page then shows data of that company.
export function CompanySwitcher({ companies, current }: Props) {
  return (
    <form action={switchCompany}>
      <select
        name="company_id"
        defaultValue={current ?? ""}
        onChange={(e) => e.currentTarget.form?.requestSubmit()}
        aria-label="Company"
        className="company-select"
      >
        {companies.map((c) => (
          <option key={c.id} value={c.id}>
            {c.code} · {c.name}
          </option>
        ))}
      </select>
    </form>
  );
}
