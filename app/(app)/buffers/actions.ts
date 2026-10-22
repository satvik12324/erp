"use server";

import { revalidatePath } from "next/cache";
import { requireCompany } from "@/lib/context";
import { friendly, num, str, type ActionState } from "@/lib/actions";

export async function addBuffer(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, company } = await requireCompany();
  const { error } = await supabase.from("item_buffers").insert({
    company_id: company.id,
    item_id: str(fd, "item_id"),
    warehouse_id: str(fd, "warehouse_id"),
    target_qty: num(fd, "target_qty"),
    remarks: str(fd, "remarks"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/buffers");
  return { ok: true, message: "Buffer added." };
}

export async function updateBuffer(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { data, error } = await supabase
    .from("item_buffers")
    .update({ target_qty: num(fd, "target_qty"), is_active: fd.get("is_active") === "on" })
    .eq("id", str(fd, "id")!)
    .select("id");
  if (error) return { error: friendly(error) };
  if (!data?.length) return { error: "Not saved: you need Buffers = Full to change targets." };
  revalidatePath("/buffers");
  return { ok: true, message: "Saved." };
}

export async function setEventReason(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const { error } = await supabase.rpc("set_buffer_event_reason", {
    p_event_id: str(fd, "event_id"), p_reason_id: str(fd, "reason_id"), p_note: str(fd, "note"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/buffers/reasons");
  return { ok: true, message: "Reason recorded." };
}

export async function decideChange(_: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase } = await requireCompany();
  const approve = str(fd, "decision") === "approve";
  const { error } = await supabase.rpc("decide_buffer_change", {
    p_proposal_id: str(fd, "proposal_id"), p_approve: approve, p_target: approve ? num(fd, "target") : null, p_note: str(fd, "note"),
  });
  if (error) return { error: friendly(error) };
  revalidatePath("/buffers/dbm");
  revalidatePath("/buffers");
  return { ok: true, message: approve ? "Approved: target changed." : "Rejected." };
}
