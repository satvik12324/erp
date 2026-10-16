-- =============================================================================
-- Migration 002 — Item master, units of measure, attributes/variants, BOM
--
-- SAP Business One mapping:
--   uoms                    ~ OUOM  Units of Measure
--   uom_groups              ~ OUGP  UoM Groups
--   uom_group_conversions   ~ UGP1  UoM group lines (alternate UoM = n base UoM)
--   item_groups             ~ OITB  Item Groups
--   items                   ~ OITM  Item Master Data
--   bom_headers / bom_lines ~ OITT / ITT1  Bill of Materials
-- Deviations:
--   * Attributes and variants are not native to B1 (B1 uses UDFs). Here an item
--     can be a template; its variants are normal items linked by template_item_id
--     and distinguished by attribute values. Industry characteristics (colour,
--     size, pack size...) are attribute data, never columns.
--   * Item codes can be generated from the item group's numbering series.
-- =============================================================================

insert into public.auth_objects (code, name, description, sort_order) values
  ('UOM',         'Units of measure', 'UoMs and UoM groups', 110),
  ('ITEM_MASTER', 'Item master data', 'Item groups, items, attributes, variants', 120),
  ('BOM',         'Bills of materials', 'BOM headers and lines', 130);

-- -----------------------------------------------------------------------------
-- 1. Units of measure
-- -----------------------------------------------------------------------------

create table public.uoms (
  id          uuid        not null default gen_random_uuid(),
  company_id  uuid        not null,
  code        text        not null,
  name        text        not null,
  decimals    smallint    not null default 0,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint uoms_pk primary key (id),
  constraint uoms_company_id_uk unique (company_id, id),
  constraint uoms_code_uk unique (company_id, code),
  constraint uoms_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint uoms_decimals_ck check (decimals between 0 and 6),
  constraint uoms_company_fk foreign key (company_id) references public.companies (id) on delete cascade
);
comment on table public.uoms is 'Units of measure per company (= B1 OUOM).';
comment on column public.uoms.decimals is 'Decimal places allowed for quantities in this unit (0 = whole units only).';

create table public.uom_groups (
  id           uuid        not null default gen_random_uuid(),
  company_id   uuid        not null,
  code         text        not null,
  name         text        not null,
  base_uom_id  uuid        not null,
  is_active    boolean     not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint uom_groups_pk primary key (id),
  constraint uom_groups_company_id_uk unique (company_id, id),
  constraint uom_groups_code_uk unique (company_id, code),
  constraint uom_groups_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint uom_groups_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint uom_groups_base_uom_fk foreign key (company_id, base_uom_id) references public.uoms (company_id, id)
);
comment on table public.uom_groups is
  'UoM group (= B1 OUGP): a base unit plus the alternate units it can be bought, stocked or sold in.';

create table public.uom_group_conversions (
  id            uuid          not null default gen_random_uuid(),
  company_id    uuid          not null,
  uom_group_id  uuid          not null,
  alt_uom_id    uuid          not null,
  alt_qty       numeric(18,6) not null default 1,
  base_qty      numeric(18,6) not null,
  created_at    timestamptz   not null default now(),
  created_by    uuid,
  updated_at    timestamptz   not null default now(),
  updated_by    uuid,
  constraint uom_group_conversions_pk primary key (id),
  constraint uom_group_conversions_uk unique (uom_group_id, alt_uom_id),
  constraint uom_group_conversions_qty_ck check (alt_qty > 0 and base_qty > 0),
  constraint uom_group_conversions_group_fk foreign key (company_id, uom_group_id)
    references public.uom_groups (company_id, id) on delete cascade,
  constraint uom_group_conversions_uom_fk foreign key (company_id, alt_uom_id)
    references public.uoms (company_id, id)
);
comment on table public.uom_group_conversions is
  'alt_qty x alt_uom = base_qty x base UoM (= B1 UGP1). Example: 1 BOX = 144 PCS. '
  'The base UoM itself is always present with 1 = 1 (added automatically).';

-- B1 puts the base UoM in every group with a 1:1 line.
create or replace function private.add_base_uom_conversion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.uom_group_conversions (company_id, uom_group_id, alt_uom_id, alt_qty, base_qty)
  values (new.company_id, new.id, new.base_uom_id, 1, 1)
  on conflict (uom_group_id, alt_uom_id) do nothing;
  return new;
end;
$$;

create trigger uom_groups_add_base_conversion
  after insert on public.uom_groups
  for each row execute function private.add_base_uom_conversion();

-- The base UoM line must stay 1:1, and the base UoM of a group cannot be changed once
-- items use the group (stock quantities are kept in base units).
create or replace function private.validate_uom_conversion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from public.uom_groups g
             where g.id = new.uom_group_id and g.base_uom_id = new.alt_uom_id)
     and new.alt_qty <> new.base_qty then
    raise exception 'The base UoM line of a UoM group must be 1 = 1' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger uom_group_conversions_validate
  before insert or update on public.uom_group_conversions
  for each row execute function private.validate_uom_conversion();

-- Converts a quantity in p_uom_id to the base UoM of p_uom_group_id. NULL if the UoM is not in the group.
create or replace function private.to_base_qty(p_uom_group_id uuid, p_uom_id uuid, p_qty numeric)
returns numeric
language sql
stable
set search_path = ''
as $$
  select p_qty * c.base_qty / c.alt_qty
  from public.uom_group_conversions c
  where c.uom_group_id = p_uom_group_id and c.alt_uom_id = p_uom_id
$$;

-- -----------------------------------------------------------------------------
-- 2. Item types (fixed behaviour layer)
-- -----------------------------------------------------------------------------

create table public.item_types (
  code        text    not null,
  name        text    not null,
  is_stocked  boolean not null,
  constraint item_types_pk primary key (code)
);
comment on table public.item_types is
  'Fixed: whether an item is held in stock. INVENTORY items get stock movements and can be buffered.';

insert into public.item_types (code, name, is_stocked) values
  ('INVENTORY',     'Inventory item',     true),
  ('NON_INVENTORY', 'Non-inventory item', false),
  ('SERVICE',       'Service',            false);

-- -----------------------------------------------------------------------------
-- 3. Item groups and items
-- -----------------------------------------------------------------------------

create table public.item_groups (
  id                              uuid        not null default gen_random_uuid(),
  company_id                      uuid        not null,
  code                            text        not null,
  name                            text        not null,
  number_range_id                 uuid,
  default_item_type               text        not null default 'INVENTORY',
  default_procurement_method      text        not null default 'BUY',
  default_replenishment_policy    text        not null default 'TO_ORDER',
  default_uom_group_id            uuid,
  is_active                       boolean     not null default true,
  created_at                      timestamptz not null default now(),
  created_by                      uuid,
  updated_at                      timestamptz not null default now(),
  updated_by                      uuid,
  constraint item_groups_pk primary key (id),
  constraint item_groups_company_id_uk unique (company_id, id),
  constraint item_groups_code_uk unique (company_id, code),
  constraint item_groups_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint item_groups_procurement_ck check (default_procurement_method in ('BUY', 'MAKE')),
  constraint item_groups_replenishment_ck check (default_replenishment_policy in ('BUFFER', 'TO_ORDER')),
  constraint item_groups_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint item_groups_item_type_fk foreign key (default_item_type) references public.item_types (code),
  constraint item_groups_range_fk foreign key (company_id, number_range_id) references public.number_ranges (company_id, id),
  constraint item_groups_uom_group_fk foreign key (company_id, default_uom_group_id) references public.uom_groups (company_id, id)
);
comment on table public.item_groups is
  'Item groups (= B1 OITB). Supply defaults for new items and, optionally, the numbering series for item codes. '
  'The counter is kept per group (scope = group code), so one series can serve all groups.';

create table public.items (
  id                    uuid        not null default gen_random_uuid(),
  company_id            uuid        not null,
  item_code             text        not null,
  name                  text        not null,
  description           text,
  item_group_id         uuid        not null,
  item_type             text        not null,
  is_purchased          boolean     not null default true,
  is_sold               boolean     not null default true,
  procurement_method    text        not null,
  replenishment_policy  text        not null,
  uom_group_id          uuid        not null,
  inventory_uom_id      uuid        not null,
  purchase_uom_id       uuid        not null,
  sales_uom_id          uuid        not null,
  is_template           boolean     not null default false,
  template_item_id      uuid,
  is_active             boolean     not null default true,
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  constraint items_pk primary key (id),
  constraint items_company_id_uk unique (company_id, id),
  constraint items_code_uk unique (company_id, item_code),
  constraint items_code_format_ck check (item_code ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,49}$'),
  constraint items_procurement_ck check (procurement_method in ('BUY', 'MAKE')),
  constraint items_replenishment_ck check (replenishment_policy in ('BUFFER', 'TO_ORDER')),
  constraint items_buffer_needs_stock_ck check (replenishment_policy = 'TO_ORDER' or item_type = 'INVENTORY'),
  constraint items_template_ck check (not (is_template and template_item_id is not null)),
  constraint items_template_self_ck check (template_item_id is distinct from id),
  constraint items_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint items_group_fk foreign key (company_id, item_group_id) references public.item_groups (company_id, id),
  constraint items_type_fk foreign key (item_type) references public.item_types (code),
  constraint items_uom_group_fk foreign key (company_id, uom_group_id) references public.uom_groups (company_id, id),
  constraint items_inventory_uom_fk foreign key (company_id, inventory_uom_id) references public.uoms (company_id, id),
  constraint items_purchase_uom_fk foreign key (company_id, purchase_uom_id) references public.uoms (company_id, id),
  constraint items_sales_uom_fk foreign key (company_id, sales_uom_id) references public.uoms (company_id, id),
  constraint items_template_fk foreign key (company_id, template_item_id) references public.items (company_id, id)
);
comment on table public.items is
  'Item master (= B1 OITM). A template item (is_template) is never transacted; its variants are normal items '
  'pointing to it through template_item_id and distinguished by variant-axis attribute values.';
comment on column public.items.procurement_method is 'BUY = purchased; MAKE = produced from its BOM.';
comment on column public.items.replenishment_policy is
  'BUFFER = make/buy-to-stock against a TOC stock buffer; TO_ORDER = replenished only against demand.';
comment on column public.items.inventory_uom_id is 'Unit stock is reported in. Stock is stored in the base UoM of the UoM group.';

-- Fills defaults from the item group, generates the item code from the group's series
-- when none is given, and checks that the item's UoMs belong to its UoM group.
create or replace function private.prepare_item()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  g public.item_groups%rowtype;
  v_base uuid;
begin
  select * into g from public.item_groups where id = new.item_group_id and company_id = new.company_id;
  if not found then
    raise exception 'Item group does not exist in this company' using errcode = '23503';
  end if;

  if tg_op = 'INSERT' then
    new.item_type            := coalesce(new.item_type, g.default_item_type);
    new.procurement_method   := coalesce(new.procurement_method, g.default_procurement_method);
    new.replenishment_policy := coalesce(new.replenishment_policy, g.default_replenishment_policy);
    new.uom_group_id         := coalesce(new.uom_group_id, g.default_uom_group_id);

    if new.uom_group_id is null then
      raise exception 'Item needs a UoM group (none given and the item group has no default)' using errcode = '23502';
    end if;

    select base_uom_id into v_base from public.uom_groups where id = new.uom_group_id;
    new.inventory_uom_id := coalesce(new.inventory_uom_id, v_base);
    new.purchase_uom_id  := coalesce(new.purchase_uom_id, new.inventory_uom_id);
    new.sales_uom_id     := coalesce(new.sales_uom_id, new.inventory_uom_id);

    if new.item_code is null then
      if g.number_range_id is null then
        raise exception 'Item code is required: item group % has no numbering series', g.code using errcode = '23502';
      end if;
      new.item_code := private.next_number(g.number_range_id, g.code, current_date);
    end if;
  end if;

  if tg_op = 'UPDATE' and new.uom_group_id <> old.uom_group_id then
    raise exception 'The UoM group of an existing item cannot be changed' using errcode = '23514';
  end if;

  if exists (
    select u.uom_id
    from (values (new.inventory_uom_id), (new.purchase_uom_id), (new.sales_uom_id)) as u(uom_id)
    where not exists (select 1 from public.uom_group_conversions c
                      where c.uom_group_id = new.uom_group_id and c.alt_uom_id = u.uom_id)
  ) then
    raise exception 'Inventory, purchase and sales UoM must all belong to the item''s UoM group' using errcode = '23514';
  end if;

  if new.template_item_id is not null and not exists (
    select 1 from public.items t where t.id = new.template_item_id and t.is_template
  ) then
    raise exception 'template_item_id must point to an item marked as template' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.is_template and not new.is_template
     and exists (select 1 from public.items v where v.template_item_id = new.id) then
    raise exception 'Item still has variants and must remain a template' using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger items_prepare
  before insert or update on public.items
  for each row execute function private.prepare_item();

-- -----------------------------------------------------------------------------
-- 4. Attributes (characteristics) and variants
-- -----------------------------------------------------------------------------

create table public.attribute_definitions (
  id               uuid        not null default gen_random_uuid(),
  company_id       uuid        not null,
  code             text        not null,
  name             text        not null,
  data_type        text        not null,
  is_variant_axis  boolean     not null default false,
  sort_order       smallint    not null default 0,
  is_active        boolean     not null default true,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint attribute_definitions_pk primary key (id),
  constraint attribute_definitions_company_id_uk unique (company_id, id),
  constraint attribute_definitions_code_uk unique (company_id, code),
  constraint attribute_definitions_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint attribute_definitions_type_ck check (data_type in ('TEXT', 'NUMBER', 'LIST')),
  constraint attribute_definitions_axis_ck check (not is_variant_axis or data_type = 'LIST'),
  constraint attribute_definitions_company_fk foreign key (company_id) references public.companies (id) on delete cascade
);
comment on table public.attribute_definitions is
  'Item characteristics defined per company (e.g. COLOUR, SIZE, PACK_SIZE). '
  'is_variant_axis = variants of a template differ by this attribute (LIST type only).';

create table public.attribute_options (
  id                       uuid        not null default gen_random_uuid(),
  company_id               uuid        not null,
  attribute_definition_id  uuid        not null,
  code                     text        not null,
  name                     text        not null,
  sort_order               smallint    not null default 0,
  is_active                boolean     not null default true,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  constraint attribute_options_pk primary key (id),
  constraint attribute_options_company_id_uk unique (company_id, id),
  constraint attribute_options_def_id_uk unique (attribute_definition_id, id),
  constraint attribute_options_code_uk unique (attribute_definition_id, code),
  constraint attribute_options_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint attribute_options_def_fk foreign key (company_id, attribute_definition_id)
    references public.attribute_definitions (company_id, id) on delete cascade
);
comment on table public.attribute_options is 'Allowed values of a LIST attribute (e.g. COLOUR: BK = Black, RD = Red).';

create table public.item_attribute_values (
  id                       uuid          not null default gen_random_uuid(),
  company_id               uuid          not null,
  item_id                  uuid          not null,
  attribute_definition_id  uuid          not null,
  option_id                uuid,
  text_value               text,
  number_value             numeric(18,6),
  created_at               timestamptz   not null default now(),
  created_by               uuid,
  updated_at               timestamptz   not null default now(),
  updated_by               uuid,
  constraint item_attribute_values_pk primary key (id),
  constraint item_attribute_values_uk unique (item_id, attribute_definition_id),
  constraint item_attribute_values_one_value_ck check (num_nonnulls(option_id, text_value, number_value) = 1),
  constraint item_attribute_values_item_fk foreign key (company_id, item_id)
    references public.items (company_id, id) on delete cascade,
  constraint item_attribute_values_def_fk foreign key (company_id, attribute_definition_id)
    references public.attribute_definitions (company_id, id),
  -- the option must belong to the same attribute definition
  constraint item_attribute_values_option_fk foreign key (attribute_definition_id, option_id)
    references public.attribute_options (attribute_definition_id, id)
);
comment on table public.item_attribute_values is
  'Value of one attribute for one item. Exactly one of option_id / text_value / number_value, matching the data type.';

create or replace function private.validate_item_attribute_value()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_type text;
begin
  select data_type into v_type from public.attribute_definitions where id = new.attribute_definition_id;
  if (v_type = 'LIST'   and new.option_id    is null)
  or (v_type = 'TEXT'   and new.text_value   is null)
  or (v_type = 'NUMBER' and new.number_value is null) then
    raise exception 'Value does not match attribute data type %', v_type using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger item_attribute_values_validate
  before insert or update on public.item_attribute_values
  for each row execute function private.validate_item_attribute_value();

-- No two variants of the same template may have the same combination of variant-axis values.
-- Checked when a variant's attribute values change (deferred so all values of a new variant
-- can be inserted in one transaction first).
create or replace function private.check_unique_variant_combination()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item_id  uuid := coalesce(new.item_id, old.item_id);
  v_template uuid;
  v_dup      text;
begin
  select template_item_id into v_template from public.items where id = v_item_id;
  if v_template is null then
    return null;
  end if;

  with combos as (
    select i.id, i.item_code,
           string_agg(d.code || '=' || o.code, ',' order by d.code) as combo
    from public.items i
    join public.item_attribute_values v on v.item_id = i.id
    join public.attribute_definitions d on d.id = v.attribute_definition_id and d.is_variant_axis
    join public.attribute_options o on o.id = v.option_id
    where i.template_item_id = v_template
    group by i.id, i.item_code
  )
  select b.item_code into v_dup
  from combos a join combos b on a.combo = b.combo and a.id <> b.id
  where a.id = v_item_id
  limit 1;

  if v_dup is not null then
    raise exception 'Variant combination already exists on item %', v_dup using errcode = '23505';
  end if;
  return null;
end;
$$;

create constraint trigger item_attribute_values_unique_variant
  after insert or update or delete on public.item_attribute_values
  deferrable initially deferred
  for each row execute function private.check_unique_variant_combination();

-- -----------------------------------------------------------------------------
-- 5. Bills of materials (multi-level by recursion: a component can have its own BOM)
-- -----------------------------------------------------------------------------

create table public.bom_headers (
  id             uuid          not null default gen_random_uuid(),
  company_id     uuid          not null,
  item_id        uuid          not null,
  base_quantity  numeric(18,6) not null default 1,
  uom_id         uuid          not null,
  remarks        text,
  is_active      boolean       not null default true,
  created_at     timestamptz   not null default now(),
  created_by     uuid,
  updated_at     timestamptz   not null default now(),
  updated_by     uuid,
  constraint bom_headers_pk primary key (id),
  constraint bom_headers_company_id_uk unique (company_id, id),
  constraint bom_headers_base_qty_ck check (base_quantity > 0),
  constraint bom_headers_item_fk foreign key (company_id, item_id) references public.items (company_id, id),
  constraint bom_headers_uom_fk foreign key (company_id, uom_id) references public.uoms (company_id, id)
);
create unique index bom_headers_one_active_ux on public.bom_headers (item_id) where is_active;
comment on table public.bom_headers is
  'BOM header (= B1 OITT). Component quantities are per base_quantity of the parent in uom_id. '
  'One active BOM per item; older versions are kept inactive.';

create table public.bom_lines (
  id                 uuid          not null default gen_random_uuid(),
  company_id         uuid          not null,
  bom_id             uuid          not null,
  line_no            integer       not null,
  component_item_id  uuid          not null,
  quantity           numeric(18,6) not null,
  uom_id             uuid          not null,
  issue_method       text          not null default 'BACKFLUSH',
  remarks            text,
  created_at         timestamptz   not null default now(),
  created_by         uuid,
  updated_at         timestamptz   not null default now(),
  updated_by         uuid,
  constraint bom_lines_pk primary key (id),
  constraint bom_lines_line_uk unique (bom_id, line_no),
  constraint bom_lines_qty_ck check (quantity > 0),
  constraint bom_lines_line_no_ck check (line_no > 0),
  constraint bom_lines_issue_method_ck check (issue_method in ('BACKFLUSH', 'MANUAL')),
  constraint bom_lines_bom_fk foreign key (company_id, bom_id)
    references public.bom_headers (company_id, id) on delete cascade,
  constraint bom_lines_component_fk foreign key (company_id, component_item_id)
    references public.items (company_id, id),
  constraint bom_lines_uom_fk foreign key (company_id, uom_id) references public.uoms (company_id, id)
);
comment on table public.bom_lines is
  'BOM components (= B1 ITT1). BACKFLUSH = issued automatically when the parent is reported complete; '
  'MANUAL = issued by a separate document.';

-- BOM header: item must not be a template; UoM must be in the item's UoM group.
create or replace function private.validate_bom_header()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  i public.items%rowtype;
begin
  select * into i from public.items where id = new.item_id;
  if i.is_template then
    raise exception 'A template item cannot have a BOM; define BOMs on its variants' using errcode = '23514';
  end if;
  if not exists (select 1 from public.uom_group_conversions c
                 where c.uom_group_id = i.uom_group_id and c.alt_uom_id = new.uom_id) then
    raise exception 'BOM UoM must belong to the UoM group of item %', i.item_code using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger bom_headers_validate
  before insert or update on public.bom_headers
  for each row execute function private.validate_bom_header();

-- BOM line: component is not a template, UoM is valid for the component, and adding the
-- component does not create a cycle at any depth (A -> B -> ... -> A).
create or replace function private.validate_bom_line()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  c         public.items%rowtype;
  v_parent  uuid;
  v_cycle   boolean;
begin
  select * into c from public.items where id = new.component_item_id;
  select item_id into v_parent from public.bom_headers where id = new.bom_id;

  if c.is_template then
    raise exception 'Template item % cannot be a BOM component; use a variant', c.item_code using errcode = '23514';
  end if;

  if not exists (select 1 from public.uom_group_conversions x
                 where x.uom_group_id = c.uom_group_id and x.alt_uom_id = new.uom_id) then
    raise exception 'Line UoM must belong to the UoM group of component %', c.item_code using errcode = '23514';
  end if;

  -- Walk down from the component through active BOMs; reaching the parent means a cycle.
  with recursive descendants(item_id) as (
    select new.component_item_id
    union
    select l.component_item_id
    from descendants d
    join public.bom_headers h on h.item_id = d.item_id and h.is_active
    join public.bom_lines l   on l.bom_id = h.id
  )
  select exists (select 1 from descendants where item_id = v_parent) into v_cycle;

  if v_cycle then
    raise exception 'Component % would create a BOM cycle', c.item_code using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger bom_lines_validate
  before insert or update on public.bom_lines
  for each row execute function private.validate_bom_line();

-- Activating an older BOM version can also close a cycle; re-check its lines.
create or replace function private.validate_bom_activation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_active and not old.is_active and exists (
    with recursive descendants(item_id) as (
      select l.component_item_id from public.bom_lines l where l.bom_id = new.id
      union
      select l.component_item_id
      from descendants d
      join public.bom_headers h on h.item_id = d.item_id and h.is_active and h.id <> new.id
      join public.bom_lines l   on l.bom_id = h.id
    )
    select 1 from descendants where item_id = new.item_id
  ) then
    raise exception 'Activating this BOM would create a cycle' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger bom_headers_validate_activation
  before update of is_active on public.bom_headers
  for each row execute function private.validate_bom_activation();

-- Fully exploded BOM of an item: every component at every level with the quantity
-- needed per 1 base unit of the top item (quantities converted to base UoMs).
create or replace function public.bom_explosion(p_item_id uuid)
returns table (
  level              integer,
  path               text,
  component_item_id  uuid,
  item_code          text,
  issue_method       text,
  qty_per_parent     numeric,
  base_uom_code      text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive tree as (
    select 1 as level,
           i.item_code::text as path,
           l.component_item_id,
           l.issue_method,
           -- component qty in its base UoM per 1 base unit of the parent
           private.to_base_qty(ci.uom_group_id, l.uom_id, l.quantity)
             / private.to_base_qty(i.uom_group_id, h.uom_id, h.base_quantity) as qty
    from public.items i
    join public.bom_headers h on h.item_id = i.id and h.is_active
    join public.bom_lines l   on l.bom_id = h.id
    join public.items ci      on ci.id = l.component_item_id
    where i.id = p_item_id
    union all
    select t.level + 1,
           t.path || ' > ' || pi.item_code,
           l.component_item_id,
           l.issue_method,
           t.qty * private.to_base_qty(ci.uom_group_id, l.uom_id, l.quantity)
                 / private.to_base_qty(pi.uom_group_id, h.uom_id, h.base_quantity)
    from tree t
    join public.items pi      on pi.id = t.component_item_id
    join public.bom_headers h on h.item_id = pi.id and h.is_active
    join public.bom_lines l   on l.bom_id = h.id
    join public.items ci      on ci.id = l.component_item_id
    where t.level < 20
  )
  select t.level, t.path, t.component_item_id, ci.item_code, t.issue_method,
         round(t.qty, 6), u.code
  from tree t
  join public.items ci       on ci.id = t.component_item_id
  join public.uom_groups g   on g.id = ci.uom_group_id
  join public.uoms u         on u.id = g.base_uom_id
  order by t.path, ci.item_code
$$;
comment on function public.bom_explosion(uuid) is
  'Multi-level BOM explosion with quantities per 1 base unit of the top item. Respects RLS (security invoker).';

-- -----------------------------------------------------------------------------
-- 6. RLS, triggers, indexes
-- -----------------------------------------------------------------------------

select private.enable_reference_rls('public.item_types');

select private.enable_company_rls('public.uoms',                  'UOM');
select private.enable_company_rls('public.uom_groups',            'UOM');
select private.enable_company_rls('public.uom_group_conversions', 'UOM');
select private.enable_company_rls('public.item_groups',           'ITEM_MASTER');
select private.enable_company_rls('public.items',                 'ITEM_MASTER');
select private.enable_company_rls('public.attribute_definitions', 'ITEM_MASTER');
select private.enable_company_rls('public.attribute_options',     'ITEM_MASTER');
select private.enable_company_rls('public.item_attribute_values', 'ITEM_MASTER');
select private.enable_company_rls('public.bom_headers',           'BOM');
select private.enable_company_rls('public.bom_lines',             'BOM');

select private.attach_standard_triggers('public.uoms');
select private.attach_standard_triggers('public.uom_groups');
select private.attach_standard_triggers('public.uom_group_conversions');
select private.attach_standard_triggers('public.item_groups');
select private.attach_standard_triggers('public.items');
select private.attach_standard_triggers('public.attribute_definitions');
select private.attach_standard_triggers('public.attribute_options');
select private.attach_standard_triggers('public.item_attribute_values');
select private.attach_standard_triggers('public.bom_headers');
select private.attach_standard_triggers('public.bom_lines');

grant execute on function private.to_base_qty(uuid, uuid, numeric) to authenticated;

create index uom_groups_base_uom_ix              on public.uom_groups (company_id, base_uom_id);
create index uom_group_conversions_uom_ix        on public.uom_group_conversions (company_id, alt_uom_id);
create index uom_group_conversions_group_ix      on public.uom_group_conversions (company_id, uom_group_id);
create index item_groups_range_ix                on public.item_groups (company_id, number_range_id);
create index item_groups_uom_group_ix            on public.item_groups (company_id, default_uom_group_id);
create index item_groups_item_type_ix            on public.item_groups (default_item_type);
create index items_group_ix                      on public.items (company_id, item_group_id);
create index items_type_ix                       on public.items (item_type);
create index items_uom_group_ix                  on public.items (company_id, uom_group_id);
create index items_inventory_uom_ix              on public.items (company_id, inventory_uom_id);
create index items_purchase_uom_ix               on public.items (company_id, purchase_uom_id);
create index items_sales_uom_ix                  on public.items (company_id, sales_uom_id);
create index items_template_ix                   on public.items (company_id, template_item_id);
create index items_name_ix                       on public.items (company_id, lower(name));
create index attribute_options_def_ix            on public.attribute_options (company_id, attribute_definition_id);
create index item_attribute_values_item_ix       on public.item_attribute_values (company_id, item_id);
create index item_attribute_values_def_ix        on public.item_attribute_values (company_id, attribute_definition_id);
create index item_attribute_values_option_ix     on public.item_attribute_values (attribute_definition_id, option_id);
create index bom_headers_item_ix                 on public.bom_headers (company_id, item_id);
create index bom_headers_uom_ix                  on public.bom_headers (company_id, uom_id);
create index bom_lines_bom_ix                    on public.bom_lines (company_id, bom_id);
create index bom_lines_component_ix              on public.bom_lines (company_id, component_item_id);
create index bom_lines_uom_ix                    on public.bom_lines (company_id, uom_id);
