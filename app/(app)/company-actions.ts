"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { COMPANY_COOKIE } from "@/lib/context";

export async function switchCompany(fd: FormData) {
  const id = String(fd.get("company_id") ?? "");
  (await cookies()).set(COMPANY_COOKIE, id, { path: "/", httpOnly: true, sameSite: "lax", maxAge: 60 * 60 * 24 * 365 });
  redirect("/");
}
