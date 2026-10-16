"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { friendly, str, upper, type ActionState } from "@/lib/actions";

export async function createReason(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("reason_codes").insert({
    company_id: company.id, reason_type: str(fd, "reason_type"), code: upper(fd, "code"), name: str(fd, "name"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/reasons");
  return { ok: true, message: "Reason added." };
}
