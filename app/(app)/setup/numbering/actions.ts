"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { friendly, num, str, upper, type ActionState } from "@/lib/actions";

export async function createRange(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("number_ranges").insert({
    company_id: company.id,
    code: upper(fd, "code"),
    name: str(fd, "name"),
    pattern: str(fd, "pattern"),
    reset_policy: str(fd, "reset_policy") ?? "NONE",
    start_number: num(fd, "start_number") ?? 1,
  });
  if (error) {
    if (error.message.includes("number_ranges_pattern_ck"))
      return { error: "The pattern must contain the counter exactly once: {N} or {N:5}." };
    return { error: friendly(error) };
  }
  revalidatePath("/setup/numbering");
  return { ok: true, message: "Series created." };
}

export async function createDocType(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("document_types").insert({
    company_id: company.id,
    code: upper(fd, "code"),
    name: str(fd, "name"),
    category: str(fd, "category"),
    default_number_range_id: str(fd, "default_number_range_id"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/setup/numbering");
  return { ok: true, message: "Document type created." };
}
