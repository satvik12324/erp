// Public connection settings. The publishable key is designed to be shipped to browsers;
// all data access is guarded by row-level security in the database.
// Environment variables override these defaults (set them in Vercel to point at another project).
export const SUPABASE_URL =
  process.env.NEXT_PUBLIC_SUPABASE_URL ?? "https://dhwaypzweuonqorsbnfd.supabase.co";

export const SUPABASE_PUBLISHABLE_KEY =
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_KLgRQhP4mJCwdwPuCufAZg_9bxVZUmt";
