import { cache } from "react";
import { requireCompany } from "@/lib/context";

export type Level = "FULL" | "READ" | "NONE";

// Authorization level per object for the selected company. Used only to hide UI the database
// would refuse anyway; the database remains the security boundary.
export const getAccess = cache(async () => {
  const { supabase, company } = await requireCompany();
  const { data } = await supabase.rpc("my_access", { p_company_id: company.id });
  const map = new Map<string, Level>((data ?? []).map((r: any) => [r.auth_object, r.level as Level]));
  return {
    level: (obj: string): Level => map.get(obj) ?? "NONE",
    can: (obj: string) => (map.get(obj) ?? "NONE") !== "NONE",
    full: (obj: string) => map.get(obj) === "FULL",
  };
});
