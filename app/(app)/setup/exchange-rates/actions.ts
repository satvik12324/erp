"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { friendly, num, str, type ActionState } from "@/lib/actions";

export async function saveRate(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("exchange_rates").upsert(
    { company_id: company.id, currency_code: str(fd, "currency_code"), rate_date: str(fd, "rate_date"), rate: num(fd, "rate") },
    { onConflict: "company_id,currency_code,rate_date" },
  );
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/exchange-rates");
  return { ok: true, message: "Rate saved." };
}
