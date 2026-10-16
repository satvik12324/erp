# TOC ERP

Multi-company ERP with Theory of Constraints built into the core. Supabase (Postgres) + Next.js on Vercel.

- Design decisions: [DECISIONS.md](DECISIONS.md)
- Database: `supabase/migrations/` (rollbacks in `supabase/rollbacks/`, dev-only seed in `supabase/seed/`, SQL tests in `supabase/tests/`)
- App: Next.js App Router (`app/`), Supabase Auth + row-level security; all business rules live in the database.

## Run locally
```
npm install
npm run dev            # http://localhost:3000, uses the live Supabase project by default
npm run test:db        # migrations up/down/up + seed + SQL tests against a local PostgreSQL
```
Connection settings: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (defaults in `lib/supabase/config.ts`).
