// API smoke test: runs the same PostgREST queries the screens use, against a local PostgREST on the
// test database (see scripts/test-db.sh), as real test users with signed JWTs. Catches embed and
// column mistakes that only show at runtime. LOCAL ONLY.
//   node scripts/api-smoke.mjs   (PostgREST on :3001, jwt-secret below)
import { PostgrestClient } from "@supabase/postgrest-js";
import crypto from "node:crypto";

const SECRET = process.env.JWT_SECRET ?? "local-test-secret-local-test-secret-0123456789";
const URL = process.env.PGRST_URL ?? "http://localhost:3001";
const USERS = {
  admin: "00000000-0000-0000-0000-00000000000a",
  planner: "00000000-0000-0000-0000-00000000000c",
  viewer: "00000000-0000-0000-0000-00000000000d",
};

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
function jwt(sub) {
  const head = b64({ alg: "HS256", typ: "JWT" });
  const body = b64({ sub, role: "authenticated", exp: Math.floor(Date.now() / 1000) + 3600 });
  const sig = crypto.createHmac("sha256", SECRET).update(`${head}.${body}`).digest("base64url");
  return `${head}.${body}.${sig}`;
}
const as = (u) => new PostgrestClient(URL, { headers: { Authorization: `Bearer ${jwt(USERS[u])}` } });

let failed = 0;
async function check(name, p, expect = (d) => true) {
  const { data, error } = await p;
  if (error || !expect(data)) {
    failed++;
    console.log(`FAIL: ${name} — ${error ? error.message : "unexpected result " + JSON.stringify(data)?.slice(0, 200)}`);
  } else console.log(`PASS: ${name}`);
  return data;
}

const admin = as("admin");
const planner = as("planner");
const { data: co } = await admin.from("companies").select("id").eq("code", "SPICE").single();
const C = co.id;
const one = async (q) => (await q.single()).data;
const item = await one(admin.from("items").select("id").eq("item_code", "RAW001").eq("company_id", C));
const fg = await one(admin.from("items").select("id").eq("item_code", "GM-500G"));
const trader = await one(admin.from("business_partners").select("id").eq("code", "S-TRADER"));

// ---- read queries exactly as the pages issue them
await check("home: recent documents", admin.from("inventory_documents").select("id, doc_number, category, doc_date, status, document_types(name)").eq("company_id", C).limit(8));
await check("items list", admin.from("items").select("id, item_code, name, item_type, procurement_method, replenishment_policy, is_template, template_item_id, is_active, item_groups(code), uom_groups(code)").eq("company_id", C).limit(5));
await check("item detail", admin.from("items").select("*, item_groups(code, name), uom_groups(code, base_uom_id)").eq("id", fg.id).maybeSingle());
await check("item attributes defs", admin.from("attribute_definitions").select("id, code, name, data_type, is_variant_axis, attribute_options(id, code, name, sort_order)").eq("company_id", C));
await check("item variants", admin.from("items").select("id, item_code, name, is_active, item_attribute_values(attribute_definition_id, option_id)").limit(3));
await check("item BOM", admin.from("bom_headers").select("id, base_quantity, uom_id, bom_lines(id, line_no, component_item_id, quantity, uom_id, issue_method, issue_warehouse_id)").eq("item_id", fg.id).eq("is_active", true).maybeSingle(), (d) => d?.bom_lines?.length === 2);
await check("item explosion rpc", admin.rpc("bom_explosion", { p_item_id: fg.id }), (d) => d.length === 5);
await check("item where-used", admin.from("bom_lines").select("bom_headers!inner(item_id, is_active, items!inner(id, item_code, name))").eq("component_item_id", item.id).eq("bom_headers.is_active", true));
await check("item stock view", admin.from("v_stock_on_hand").select("warehouse_id, warehouse_code, on_hand, base_uom").eq("item_id", item.id), (d) => d.length === 1);
await check("item suppliers", admin.from("item_suppliers").select("*, business_partners(code, name)").eq("item_id", item.id), (d) => d.length === 1);
await check("uom groups", admin.from("uom_groups").select("id, code, name, base_uom_id, uom_group_conversions(id, alt_uom_id, alt_qty, base_qty)").eq("company_id", C));
await check("numbering counters", admin.from("number_range_counters").select("number_range_id, scope_key, period_key, next_number").eq("company_id", C));
await check("inventory list", admin.from("inventory_documents").select("id, doc_number, doc_date, status, reference, remarks, created_at, document_types(code, name), inventory_document_lines(count)").eq("company_id", C));
await check("partners list", admin.from("business_partners").select("id, code, name, bp_type, currency_code, default_lead_time_days, phone, is_active").eq("company_id", C), (d) => d.length === 3);
await check("partner item suppliers", admin.from("item_suppliers").select("*, items(item_code, name)").eq("business_partner_id", trader.id), (d) => d.length === 3);
await check("my_access rpc", planner.rpc("my_access", { p_company_id: C }), (d) => d.find((x) => x.auth_object === "PURCHASING")?.level === "FULL");

// ---- purchasing flow through the API, as the actions do it
const poType = await one(admin.from("document_types").select("id").eq("company_id", C).eq("code", "PO"));
const grpoType = await one(admin.from("document_types").select("id").eq("company_id", C).eq("code", "GRPO"));
const po = await check("create PO (planner)", planner.from("purchase_orders").insert({ company_id: C, document_type_id: poType.id, business_partner_id: trader.id, doc_date: "2026-10-15" }).select("id").single());
const line = await check("add PO line", planner.from("purchase_order_lines").insert({ company_id: C, purchase_order_id: po.id, line_no: 10, item_id: item.id, quantity: 25 }).select("id").single());
await check("planner cannot price", planner.from("purchase_order_line_prices").upsert({ company_id: C, purchase_order_line_id: line.id, unit_price: 210 }, { onConflict: "purchase_order_line_id" }).then((r) => ({ data: r.error ? "refused" : null, error: null })), (d) => d === "refused");
await check("admin sets price", admin.from("purchase_order_line_prices").upsert({ company_id: C, purchase_order_line_id: line.id, unit_price: 210, discount_pct: 0 }, { onConflict: "purchase_order_line_id" }));
await check("release rpc", planner.rpc("release_purchase_order", { p_po_id: po.id }), (d) => typeof d === "string" && d.startsWith("PO/"));
await check("PO detail", admin.from("purchase_orders").select("*, business_partners(id, code, name), document_types(name)").eq("id", po.id).maybeSingle(), (d) => d?.status === "OPEN");
await check("PO lines", admin.from("purchase_order_lines").select("*, items(item_code, name, uom_groups(base_uom_id))").eq("purchase_order_id", po.id), (d) => d.length === 1);
await check("PO prices (admin)", admin.from("purchase_order_line_prices").select("purchase_order_line_id, unit_price, discount_pct").in("purchase_order_line_id", [line.id]), (d) => d.length === 1);
await check("PO prices hidden (planner)", planner.from("purchase_order_line_prices").select("purchase_order_line_id").in("purchase_order_line_id", [line.id]), (d) => d.length === 0);
await check("PO list", admin.from("purchase_orders").select("id, doc_number, doc_date, required_date, status, currency_code, supplier_reference, business_partners(code, name), purchase_order_lines(count)").eq("company_id", C).in("status", ["DRAFT", "OPEN"]));
await check("open PO lines view", admin.from("v_open_po_lines").select("*").eq("company_id", C), (d) => d.some((r) => r.purchase_order_line_id === line.id));
await check("on order view", admin.from("v_on_order").select("item_id, warehouse_id, on_order").eq("company_id", C), (d) => d.some((r) => r.item_id === item.id && Number(r.on_order) === 25));

const doc = await check("create GRPO draft", admin.from("inventory_documents").insert({ company_id: C, document_type_id: grpoType.id, business_partner_id: trader.id, doc_date: "2026-10-22", reference: "DN-1" }).select("id").single());
await check("open POs for copy", admin.from("purchase_orders").select("id, doc_number, doc_date").eq("business_partner_id", trader.id).eq("status", "OPEN"), (d) => d.length >= 1);
await check("fill from PO rpc", admin.rpc("fill_receipt_from_po", { p_document_id: doc.id, p_po_id: po.id }), (d) => d === 1);
await check("GRPO detail", admin.from("inventory_documents").select("*, document_types(code, name), business_partners(code, name)").eq("id", doc.id).maybeSingle(), (d) => d?.business_partners?.code === "S-TRADER");
await check("GRPO lines with PO ref", admin.from("inventory_document_lines").select("id, line_no, item_id, direction, quantity, uom_id, quantity_base, warehouse_id, to_warehouse_id, remarks, purchase_order_line_id, items(item_code, name, uom_groups(base_uom_id)), purchase_order_lines(line_no, purchase_order_id, purchase_orders(doc_number))").eq("document_id", doc.id), (d) => d[0]?.purchase_order_lines?.purchase_orders?.doc_number?.startsWith("PO/"));
await check("post rpc", admin.rpc("post_inventory_document", { p_document_id: doc.id, p_override_reason_id: null }), (d) => typeof d === "string");
await check("PO receipts list", admin.from("inventory_document_lines").select("document_id, inventory_documents(id, doc_number, doc_date, status, reverses_document_id)").in("purchase_order_line_id", [line.id]), (d) => d.length === 1);
await check("PO closed after full receipt", admin.from("purchase_orders").select("status, close_type").eq("id", po.id).single(), (d) => d.status === "CLOSED");
await check("lead time stats", admin.from("v_item_supplier_lead_time").select("*").eq("company_id", C), (d) => d.some((r) => r.item_id === item.id && r.receipts === 1));
await check("projected stock view", admin.from("v_projected_stock").select("*").eq("company_id", C).limit(5));
await check("movements on doc", admin.from("stock_movements").select("id, item_id, warehouse_id, quantity_base, balance_after, override_reason_code_id").eq("document_id", doc.id), (d) => d.length === 1);
await check("viewer sees open PO lines (INVENTORY=READ)", as("viewer").from("v_open_po_lines").select("purchase_order_line_id").eq("company_id", C));

console.log(failed ? `${failed} FAILED` : "ALL API CHECKS PASSED");
process.exit(failed ? 1 : 0);
