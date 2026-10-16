-- Rollback for 20261015000002_items.sql

drop function if exists public.bom_explosion(uuid);

drop table if exists public.bom_lines;
drop table if exists public.bom_headers;
drop table if exists public.item_attribute_values;
drop table if exists public.attribute_options;
drop table if exists public.attribute_definitions;
drop table if exists public.items;
drop table if exists public.item_groups;
drop table if exists public.item_types;
drop table if exists public.uom_group_conversions;
drop table if exists public.uom_groups;
drop table if exists public.uoms;

drop function if exists private.validate_bom_activation();
drop function if exists private.validate_bom_line();
drop function if exists private.validate_bom_header();
drop function if exists private.check_unique_variant_combination();
drop function if exists private.validate_item_attribute_value();
drop function if exists private.prepare_item();
drop function if exists private.to_base_qty(uuid, uuid, numeric);
drop function if exists private.validate_uom_conversion();
drop function if exists private.add_base_uom_conversion();

delete from public.role_permissions where auth_object in ('UOM', 'ITEM_MASTER', 'BOM');
delete from public.auth_objects where code in ('UOM', 'ITEM_MASTER', 'BOM');
