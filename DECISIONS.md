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

## D-028 — 2026-10-16 — Build module by module, no calendar plan
**Decision:** The 8-week plan in D-001/D-002 is replaced by building one module at a time, each finished end to end (schema, tests, live database) before the next. Scope of the first usable version is unchanged.
**Reason:** Owner's instruction: the system is in its build phase; finishing modules matters more than week labels.

## D-029 — 2026-10-16 — Inventory tracks quantities only
**Decision:** No stock valuation (no moving average, no cost layers) in the inventory module. Truly variable cost for throughput will come from purchase prices when purchasing is built.
**Reason:** Owner's decision; there is no GL to post valuation to (Rule 3).

## D-030 — 2026-10-16 — Warehouses and default warehouse logic
**Decision:** Each company has warehouses with exactly one default (main). The warehouse for a line is resolved as: line value → BOM line issue warehouse (backflush) → item default warehouse → company main. Same order as B1 (document line → ITT1 warehouse → OITM default warehouse).
**Reason:** GCW has two warehouses with one main; stock must leave from different warehouses.

## D-031 — 2026-10-16 — Inventory documents, ledger and posting
**Decision:**
- One header/line structure for goods receipt, goods issue, inventory transfer and receipt from production; behaviour by the fixed category of the document type.
- DRAFT is editable/deletable. Posting (`post_inventory_document`) assigns the number from the type's series, writes the append-only ledger `stock_movements` and updates `item_warehouse_stock`, in one transaction. Posted documents are immutable; `cancel_inventory_document` posts a reversing document (B1 Cancel) and requires a CANCELLATION reason.
- Negative stock is refused unless the company allows it or the user has STOCK_OVERRIDE=FULL and gives a NEGATIVE_STOCK_OVERRIDE reason, stored on the movement (D-018).
- Stock rows are locked in a fixed order during posting, so concurrent postings queue; tested with two sessions issuing the same stock.
- `fill_production_receipt` builds a receipt from production from the active BOM: one product line, one line per BACKFLUSH component, single level, quantities scaled through UoM conversions. MANUAL components are issued with a goods issue.
- Opening stock = goods receipt with an OPENING_STOCK reason.
**Deviation from B1:** No production order yet (comes with the production/DBR module).

## D-032 — 2026-10-16 — Reference master data readable by all company users
**Decision:** Warehouses and units of measure (uoms, uom_groups, uom_group_conversions) can be read by every user assigned to the company; changing them still needs FULL on WAREHOUSES / UOM.
**Reason:** Found by tests: a user with INVENTORY=READ could not see warehouse or unit codes on stock screens. These tables hold no sensitive data.

## D-033 — 2026-10-16 — Serial and batch numbers deferred
**Decision:** No serial/batch tracking yet. Bicycles do carry serial numbers; tracking will be added as its own module (B1 OSRN/OBTN equivalent) later.

## D-034 — 2026-10-22 — ERPNext as secondary reference design
**Decision:** Keep this system; use ERPNext's data model as a second reference next to SAP B1 (read the design, copy no code).
**Reason:** Owner's choice (option 3 of 3). Copying ERPNext code is not possible across stacks (Python/Frappe/MariaDB) and would make the system GPL-3.0; switching to ERPNext would discard the TOC-first core.
**Rejected:** Porting ERPNext source; replacing this system with ERPNext + a TOC app.

## D-035 — 2026-10-22 — Business partners
**Decision:** One `business_partners` table for suppliers and customers (type SUPPLIER / CUSTOMER / BOTH, = B1 OCRD), company-owned (D-004), with addresses, contacts and registration IDs as child tables. A default currency (NULL = company base) and a default lead time per partner.
**Store users** (INVENTORY=READ) can read partners and open POs so they can receive goods without purchasing rights.

## D-036 — 2026-10-22 — Purchase orders
**Decision:**
- Header/lines as B1 OPOR/POR1. DRAFT is free to edit/delete; `release_purchase_order` assigns the number, freezes currency and the exchange rate of the PO date (refused if no rate exists, D-010) and sets OPEN.
- Two dates per line (from ERPNext): `required_date` (when we need it) and `expected_date` (supplier promise; defaults to PO date + item-supplier or supplier lead time).
- Open POs may change quantity (not below received), dates, remarks and add lines; supplier, currency, rate, date and number are frozen.
- Line short-close and whole-PO close need a PO_CLOSE reason; closed quantities stop counting as on order. A PO closes itself when everything open is received (close_type RECEIVED) and reopens if such a receipt is cancelled. Cancel only without receipts.
- No approval workflow yet (single user). No PDF yet.
**Defaults taken without owner answer (2026-10-22):** prices recorded on lines; no approval; PDF later; supplier import from Airtable only after owner confirms.

## D-037 — 2026-10-22 — Purchase prices kept apart
**Decision:** Prices live in `purchase_order_line_prices` (unit price, discount %, in PO currency per PO unit), guarded by PURCHASE_PRICES. Users with PURCHASING but not PURCHASE_PRICES see and receive POs without prices.
**Reason:** Applies D-008 (costs hidden from store via separate tables; RLS cannot hide columns).

## D-038 — 2026-10-22 — Goods receipt PO
**Decision:** Goods receipt PO (= B1 OPDN/PDN1, ERPNext Purchase Receipt) is an inventory document category with a supplier on the header and a PO line link per line. Posting updates the PO line's received quantity through a trigger on the stock ledger, inside the posting transaction; cancellation (reversal) reduces it again. `fill_receipt_from_po` copies open quantities (B1 Copy From). Receipts without a PO are allowed (no link).
**Over-receipt:** refused beyond `company_settings.over_receipt_pct` (default 0) unless the user has OVER_RECEIPT=FULL (ERPNext over_delivery_receipt_allowance + role).

## D-039 — 2026-10-22 — Lead time and on-order views
**Decision:** `v_purchase_lead_times` (per receipt line: receipt date − PO date, days late vs expected), `v_item_supplier_lead_time` (count, average, 80th percentile, max, % on time, next to planned), `v_on_order` (= B1 OITW.OnOrder / ERPNext Bin.ordered_qty), `v_projected_stock` (on hand + on order; reserved from sales orders will be subtracted when sales exists → TOC net-flow position). All views, no stored counters.

## D-040 — 2026-10-22 — Sales orders with time buffers
**Decision:**
- Header/lines as B1 ORDR/RDR1, built the same way as purchase orders (D-036). The life cycle is DRAFT → OPEN → CLOSED/CANCELLED. `release_sales_order` assigns the number, freezes the exchange rate (D-010) and fixes the time buffer.
- Every order needs a **due date** (the date promised to the customer) to be released. It also has a **time buffer** in days (`company_settings.default_time_buffer_days`, default 14, can be changed per order). On an open order, only the due date and buffer can be rescheduled.
- Prices are kept in `sales_order_line_prices`, guarded by SALES_PRICES (same pattern as D-037). Store users (INVENTORY=READ) can read open orders so they can deliver.
- Closing short needs an SO_CLOSE reason. An order closes itself when fully delivered and reopens if that delivery is cancelled. An order can only be cancelled if nothing has been delivered.
**SAP difference:** B1 has no time buffer. The due date stands in for B1's DocDueDate. Priority comes from buffer penetration, not from the due date.
**Rejected:** One buffer per line. Orders ship as a whole in both current businesses, and a header buffer keeps the board readable. Revisit if partial shipping becomes normal.

## D-041 — 2026-10-22 — Order buffer status
**Decision:**
- `v_sales_order_buffer` computes everything live; nothing is stored.
  - buffer start = due date − buffer days
  - penetration = (today − buffer start) ÷ buffer days
  - zone uses the company cut-points (D-012); BLACK is above 100% (late)
- "Today" is the company's local date (`private.company_today`, from companies.timezone), not the UTC date.
- The board also shows a simple stock check: each open line compared with on hand in its warehouse, ignoring competing orders. This is not yet a full-kit allocation.

## D-042 — 2026-10-22 — Delivery
**Decision:** Delivery (= B1 ODLN/DLN1) is an inventory document category, mirroring goods receipt PO (D-038):
- A customer on the header and an SO line link on each line.
- A trigger on the stock ledger updates the delivered quantity.
- `fill_delivery_from_so` copies the open quantities into the delivery.
- Over-delivery uses the same tolerance and OVER_RECEIPT permission as over-receipt.
**Reserved stock** (`v_reserved`, = B1 IsCommited) is the open SO quantity. `v_projected_stock` is now on hand + on order − reserved.

## D-043 — 2026-10-22 — Stock buffers and replenishment
**Decision:**
- `item_buffers` holds one target quantity (in the base unit) per item and warehouse. Only items with replenishment policy BUFFER can have one; templates cannot.
- `v_buffer_status` works out the following:
  - **allocated** = open SO quantity of lines whose order buffer has started, plus **spikes** (a single line ≥ `spike_threshold_pct` of the target, default 50%, counted straight away whatever its date)
  - **available** = on hand − allocated
  - **penetration** = (target − available) ÷ target; BLACK when available ≤ 0
  - **net flow** = on hand + on order − allocated
  - **to replenish** = target − net flow (minimum 0)
- `v_replenishment` lists buffers below target, plus TO_ORDER items whose open orders exceed on hand + on order.
  - It adds the preferred supplier, lead time, and the order quantity in the supplier's unit, rounded up to the minimum and multiple.
  - BUY lines become draft POs, one per supplier, after the user selects them. MAKE lines are listed until the production module exists.
**Rejected:** Allocating every open order straight away, which hides when demand is actually due and over-replenishes for orders far in the future. Treating spikes as separate make-to-order demand, which needs order-specific supply tracking we don't have yet.

## D-044 — 2026-10-22 — Buffer history, red/black reasons, DBM
**Decision:**
- `take_buffer_snapshot(company)` writes one row per stock buffer and per open order per day.
  - Running it again the same day replaces that day's zone.
  - It runs from the boards when they open, and daily by schedule where pg_cron exists.
- Entering RED, or BLACK, from a better zone creates a `buffer_events` row. The user records the cause (BUFFER_RED / BUFFER_BLACK reason plus a note). The Pareto ranks causes over a chosen period.
- DBM is based on the snapshots:
  - all of the last `dbm_red_days` (default 7) in red or black → INCREASE proposal
  - all of the last `dbm_green_days` (default 30) in green → DECREASE proposal
  - the step is `dbm_step_pct` (default 33%)
  - nothing is proposed while the target changed inside the window, or after a rejection inside the window
- A pending proposal expires as soon as its condition breaks. The target changes only through `decide_buffer_change`, where the approver can adjust the quantity (Rule 4: never auto-change).
- Snapshots, events and proposals are written only by functions; the API cannot insert, update or delete them.
**Rejected:** Recomputing history from the stock ledger on demand: stock buffers could be rebuilt that way, but order zones depend on due dates that may have been rescheduled since.

## D-045 — 2026-10-22 — Scheduled snapshots
**Decision:** pg_cron job `erp-buffer-snapshots` runs `take_buffer_snapshot` for every active company hourly at :05. Hourly rather than daily because each company's "day" follows its own time zone; the snapshot is idempotent per local day. Boards also refresh it when opened.
