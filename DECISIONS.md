# DECISIONS.md

Running log of design decisions. Format: ID — date — decision — reason — alternatives rejected.
Reference model for anything not TOC-related: SAP Business One (B1).

---

## D-001 — 2026-10-14 — MVP scope and deadline
**Decision:** Build an 8-week MVP for Gupta Cycle Works only, usable by mid-December 2026.
In scope: minimal platform, items/UoM/BOM, warehouses and stock movements, kit completion with backflush, purchase orders and goods receipts with lead-time capture, sales orders with time buffers and full-kit check, delivery, buffer board, replenishment proposal, DBM flags, red/black reason codes.
Deferred: invoices, tax codes, payments, export documents (PI/CI/packing list), DBR constraint load, CCPM, throughput dashboards, exchange-difference handling, second company going live.
**Reason:** The two-month deadline is hard. GCW's immediate problems are no BOM, no BOM-based stock deduction, stock-outs, unrecorded lead times and poor order visibility. The MVP targets exactly those.
**Rejected:** The full 7-phase brief before go-live (6–12 months).

## D-002 — 2026-10-14 — Phase order changed
**Decision:** Purchasing and goods receipts (weeks 4–5) come before sales orders (weeks 5–6).
**Reason:** Stock-outs and unknown lead times are the most urgent pain. Lead-time history only starts once receipts are recorded.
**Rejected:** The brief's order (sales before purchasing).

## D-003 — 2026-10-14 — SAP Business One as reference model
**Decision:** For anything not TOC-related, follow B1 practice and note deviations explicitly.
**Reason:** The owner's operating reference. Avoids inventing business rules.
**Rejected:** Mixed SAP ECC/B1 conventions; invented conventions.

## D-004 — 2026-10-14 — Master data is company-owned, never shared
**Decision:** Every master table has `company_id NOT NULL`. The same supplier or item used by two companies exists as two records. Cross-company links (intercompany item mapping, group reporting keys) are added later as separate reference tables.
**Reason:** Owner's requirement. Matches B1 (one database per company, no shared masters). Gives one simple RLS pattern and no cross-company edit rights.
**Overrides:** Project brief Rule 2 ("masters can be shared, controlled by a flag").
**Rejected:** Nullable `company_id` + shared flag; master-to-company assignment table; physically separate tables per company.

## D-005 — 2026-10-14 — One database, company_id + RLS
**Decision:** One Supabase database. Every company-scoped table carries `company_id`. RLS limits rows to the companies a user is assigned to.
**Reason:** Project brief. Group reporting is possible without cross-database queries.
**Deviation from B1:** B1 uses one database per company.

## D-006 — 2026-10-14 — Fixed behaviour layer + configurable labels
**Decision:**
- Fixed reference tables, changed only by migration: `document_categories` (= B1 object types such as Sales Order, Delivery, Purchase Order, Goods Receipt), `system_statuses` (DRAFT, OPEN, RELEASED, PARTIAL, COMPLETED, CLOSED, CANCELLED) and `reason_types`.
- Configurable per company: `document_types` (= B1 numbering series + name), `status_definitions` (user statuses mapped to a system status) and `reason_codes`.
**Reason:** Code behaviour (stock posting, open items, release logic) must hang off fixed categories. Users can still add unlimited types, statuses and reasons. Same split as B1 object types vs numbering series, and SAP system status vs user status.
**Rejected:** Postgres enums (values can't be removed). Fully configurable behaviour flags on document types (untestable combinations; a wrong flag silently corrupts stock).

## D-007 — 2026-10-14 — Authorizations, B1 style
**Decision:** Permissions are granted per authorization object at levels FULL / READ / NONE. Roles act as B1 authorization groups, assigned per user per company. Superuser is a per-company flag.
MVP: one superuser (the owner). Role and permission tables exist but stay minimal until more users are added.
**Reason:** B1 General Authorizations model. Only one user through development and the initial run.
**Rejected:** Separate read/write permission codes; a global group-admin flag.

## D-008 — 2026-10-14 — Cost and price visibility
**Decision:** Cost and price fields live in separate tables (e.g. `item_costs`), guarded by RLS on a `cost` authorization object.
**Reason:** RLS hides rows, not columns.
**Rejected:** Column-level GRANTs (all Supabase users share the `authenticated` role); views that null out costs (base tables stay exposed).

## D-009 — 2026-10-14 — Numbering series
**Decision:**
- `number_ranges` = B1 numbering series. A document type can have several series plus a default.
- An optional fiscal-year period key resets numbering each FY.
- `number_range_counters.scope_key` keeps separate counters within one series (e.g. per item group, for CAT-NNNN-VV).
- `private.next_number()` locks the counter row `FOR UPDATE`, so numbering is gapless: a rolled-back transaction doesn't consume a number.
**Reason:** B1 behaviour. Indian invoice series must be consecutive.
**Rejected:** Postgres sequences (gaps on rollback).

## D-010 — 2026-10-14 — Currency model
**Decision:**
- Each document stores its transaction currency, the exchange rate at document date, and amounts in local (company base) currency frozen at that rate.
- No B1 system currency. Group views convert to a chosen reporting currency at report time.
- Exchange rates are entered manually per company, as in B1: 1 foreign currency = rate × company base currency (direct quotation). *(Revised 2026-10-15: rates are company-owned, consistent with D-004.)*
- A foreign-currency document cannot be saved without a rate for its date.
- Restricting each company to a list of allowed currencies is deferred.
**Reason:** Owner wants two currency roles (transaction and local). The brief requires a chosen reporting currency for group views. Frozen local amounts keep single-company reports stable.
**Accepted trade-off:** Group figures can shift when rates are edited; single-company figures cannot.
**Rejected:** B1 FC/LC/SC triple amounts; automatic rate fetch.

## D-011 — 2026-10-14 — Exchange differences deferred
**Decision:** The difference between the document rate and the payment rate is not handled in the MVP.
**Reason:** Payments are out of MVP scope. The issue matters mainly for GCW International.
**Open risk:** Throughput per order excludes realized exchange differences until this is designed.

## D-012 — 2026-10-14 — Buffer zone thresholds
**Decision:** Thresholds are configurable per company via `company_settings`: `yellow_from_pct = 34`, `red_from_pct = 67`. A zone applies from its cut-point upward (>=). Black means penetration above 100%.
**Reason:** Matches the brief (green 0–33, yellow 34–66, red 67–100, black >100) with unambiguous boundaries.

## D-013 — 2026-10-14 — Deletion rules
**Decision:** Master data can be deleted only if no document references it (`ON DELETE RESTRICT`); otherwise it is set inactive. Documents are never deleted, only cancelled.
**Reason:** B1 behaviour.
**Rejected:** Blanket no-delete rule.

## D-014 — 2026-10-14 — Audit trail
**Decision:** One generic trigger writes every insert, update and delete to an append-only `audit_log`: old/new row as jsonb, changed columns, user, timestamp, transaction ID. Reading it requires the `audit` authorization.
**Reason:** B1 change log equivalent. Required by the brief.

## D-015 — 2026-10-14 — Migrations and seed data
**Decision:**
- Supabase CLI migrations in `supabase/migrations/`. Each has a matching down script in `supabase/rollbacks/`, tested up → down → up.
- Seed data lives in paired dev-only files (`seed/`), never applied to production.
- Seed covers two fictional companies with different base currencies: a CAD trading company and an INR food producer.
- Real companies are created through the app.
**Reason:** The Supabase CLI has no down migrations. Seed data inside migrations would put test companies into production.
**Rejected:** Seed data embedded in each migration (literal reading of the brief).

## D-016 — 2026-10-14 — Invoicing stays in Tally Gold
**Decision:** No invoices or tax codes in the MVP. Tax codes move to Phase 3 (post-MVP). GCW keeps invoicing in Tally Gold.
**Accepted trade-off:** Shipments are entered in both systems until invoicing moves or a Tally export exists.

## D-017 — 2026-10-14 — Receipt from production with backflush
**Decision:** One "receipt from production" document issues BACKFLUSH components per the active BOM and receives the finished item into stock, in a single transaction, when the item is reported complete (before shipping). No WIP stage. *(Renamed 2026-10-15 from "kit completion" to keep the schema industry-neutral.)*
**Reason:** Owner's requirement. Equivalent to a B1 production order with backflush issue method plus Receipt from Production, combined.
**Rejected:** Separate issue and receipt documents; deducting at dispatch.

## D-018 — 2026-10-14 — Negative stock blocked
**Decision:** Postings that would take stock below zero are rejected. A supervisor can override with a mandatory reason code; the override is audited.
**Reason:** Forces receipt discipline so the buffer board stays trustworthy. B1 "block negative inventory" setting.

## D-019 — 2026-10-14 — Variants are stock items
**Decision:** Each combination of variant-axis attributes is its own stock item with its own BOM (a variant of a template item). For GCW this means one finished item per model × size × frame colour, with the frame in its BOM.
**Reason:** Owner's requirement. Finished stock can be allocated to orders by attribute (e.g. colour). Colour, size etc. are attribute data (D-025), never columns.
**Supersedes:** The Airtable design where frames were picked per order outside the BOM.

## D-020 — 2026-10-14 — Lead times and buffers start from estimates
**Decision:** Initial lead times and buffer targets are entered from people's judgement. Every goods receipt records actual lead time (receipt date − PO date) per item and supplier. DBM adjusts targets from there. Purchase history is not imported.
**Reason:** Existing purchase history is of uncertain value. TOC buffers are expected to start rough and be corrected by DBM.
**Expectation:** Heavy red/black in the first weeks while buffers calibrate.

## D-021 — 2026-10-14 — Delivery document in MVP
**Decision:** The MVP includes a delivery (dispatch) document that removes finished items from stock against sales orders.
**Reason:** Finished items are stocked at receipt from production (D-017), so they need a document to leave stock.

## D-022 — 2026-10-14 — UI and hosting
**Decision:** Desktop-first, English UI. Supabase project `gcw-erp` (ref `dhwaypzweuonqorsbnfd`) in Mumbai (ap-south-1), because daily users are in Ludhiana.
**Rejected:** The first project in us-west-2 (Oregon), ~250–300 ms round trips from Ludhiana. Paused 2026-10-15; region cannot be changed after creation.

## D-023 — 2026-10-14 — Go-live and users
**Decision:** The owner is the only user and superuser through development. The owner will run the system on site in Ludhiana for several months before training other staff. Go-live training is outside the build scope.

## D-024 — 2026-10-15 — Platform admin creates companies
**Decision:** `user_profiles.is_platform_admin` allows calling `public.create_company()`, which creates the company with default settings and makes the caller its superuser. The flag can only be set via SQL (service role); users cannot change it through the API.
**Reason:** Bootstrapping: someone must be able to create a company before any company-level authorization exists. Companies cannot be inserted directly.
**Rejected:** Letting any signed-in user create companies; a global group-admin with rights inside every company.

## D-025 — 2026-10-15 — Generic item master (Rule 1)
**Decision:**
- Units: `uoms`, `uom_groups`, `uom_group_conversions` (= B1 OUOM/OUGP/UGP1). Each item has one UoM group and inventory/purchase/sales UoMs inside it. Stock will be kept in the group's base UoM.
- Characteristics: `attribute_definitions` (TEXT/NUMBER/LIST), `attribute_options`, `item_attribute_values`. LIST attributes can be variant axes.
- Variants: a template item (never transacted, no BOM) with variant items linked by `template_item_id`; duplicate attribute combinations are rejected.
- Item codes: entered, or generated from the item group's numbering series with the group code as scope (`{SCOPE}-{N:4}` gives HW-0001, CL-0001...). The GCW CAT-NNNN-VV format will be configured this way, not coded.
- BOM: `bom_headers`/`bom_lines` (= OITT/ITT1), one active BOM per item, multi-level through recursion, cycles rejected at any depth, issue method BACKFLUSH/MANUAL per line. `bom_explosion()` returns per-unit quantities in base UoMs.
- Fixed behaviour sets kept as check constraints: procurement BUY/MAKE, replenishment BUFFER/TO_ORDER, item types INVENTORY/NON_INVENTORY/SERVICE. Only INVENTORY items can be buffered.
**Reason:** Project brief Rule 1. B1 has no native variants; this follows the brief instead.

## D-026 — 2026-10-15 — Same-company integrity by composite foreign keys
**Decision:** Every company-scoped table has `unique (company_id, id)`, and references between company-scoped tables use composite foreign keys `(company_id, x_id)`. A row can never point to another company's master data, independent of RLS.
**Reason:** RLS filters what users see; it does not stop a mis-built insert from linking companies. The database guarantees it.

## D-027 — 2026-10-15 — Testing approach
**Decision:** Migrations are tested locally on PostgreSQL with a shim for Supabase auth (`supabase/tests/local_supabase_shim.sql`): up → down → up, dev seed, SQL assertion tests, and a two-session concurrency test for numbering (`scripts/test-db.sh`). Only migrations are applied to the hosted project; seed and tests never are.
