import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { cache } from "react";
import { createClient } from "@/lib/supabase/server";

export const COMPANY_COOKIE = "erp_company";

export type Company = {
  id: string;
  code: string;
  name: string;
  base_currency: string;
  fiscal_year_start_month: number;
};

// Signed-in user, the companies they are assigned to, and the company currently selected.
// Cached per request.
export const getContext = cache(async () => {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const [{ data: companies }, { data: profile }] = await Promise.all([
    supabase.from("companies").select("id, code, name, base_currency, fiscal_year_start_month").eq("is_active", true).order("code"),
    supabase.from("user_profiles").select("display_name, default_company_id, is_platform_admin").eq("user_id", user.id).single(),
  ]);

  const list = (companies ?? []) as Company[];
  const wanted = (await cookies()).get(COMPANY_COOKIE)?.value ?? profile?.default_company_id;
  const company = list.find((c) => c.id === wanted) ?? list[0] ?? null;

  return { supabase, user, profile, companies: list, company };
});

// Same as getContext, but the page needs a selected company.
export async function requireCompany() {
  const ctx = await getContext();
  if (!ctx.company) redirect("/no-company");
  return { ...ctx, company: ctx.company };
}
