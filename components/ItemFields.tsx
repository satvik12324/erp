type Opt = { id: string; code: string; name?: string };

// Shared item master fields for the create and edit forms. Empty selects mean "take the item group default"
// on create, and "unchanged" on edit.
export function ItemFields({
  item,
  uoms,
  warehouses,
}: {
  item?: any;
  uoms: Opt[];
  warehouses: Opt[];
}) {
  return (
    <div className="form-grid">
      <label style={{ gridColumn: "span 2" }}>Name<input name="name" defaultValue={item?.name} required /></label>
      <label style={{ gridColumn: "span 2" }}>Description<input name="description" defaultValue={item?.description ?? ""} /></label>
      <label>Type
        <select name="item_type" defaultValue={item?.item_type ?? ""}>
          {!item && <option value="">From group</option>}
          <option value="INVENTORY">Inventory</option>
          <option value="NON_INVENTORY">Non-inventory</option>
          <option value="SERVICE">Service</option>
        </select>
      </label>
      <label>Procurement
        <select name="procurement_method" defaultValue={item?.procurement_method ?? ""}>
          {!item && <option value="">From group</option>}
          <option value="BUY">Buy</option>
          <option value="MAKE">Make</option>
        </select>
      </label>
      <label>Replenishment
        <select name="replenishment_policy" defaultValue={item?.replenishment_policy ?? ""}>
          {!item && <option value="">From group</option>}
          <option value="BUFFER">Buffer (to stock)</option>
          <option value="TO_ORDER">To order</option>
        </select>
      </label>
      <label>Default warehouse
        <select name="default_warehouse_id" defaultValue={item?.default_warehouse_id ?? ""}>
          <option value="">Company main</option>
          {warehouses.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name}</option>)}
        </select>
      </label>
      <label>Inventory UoM
        <select name="inventory_uom_id" defaultValue={item?.inventory_uom_id ?? ""}>
          <option value="">{item ? "—" : "Base of UoM group"}</option>
          {uoms.map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
        </select>
      </label>
      <label>Purchase UoM
        <select name="purchase_uom_id" defaultValue={item?.purchase_uom_id ?? ""}>
          <option value="">{item ? "—" : "Same as inventory"}</option>
          {uoms.map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
        </select>
      </label>
      <label>Sales UoM
        <select name="sales_uom_id" defaultValue={item?.sales_uom_id ?? ""}>
          <option value="">{item ? "—" : "Same as inventory"}</option>
          {uoms.map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
        </select>
      </label>
      <label className="check"><input type="checkbox" name="is_purchased" defaultChecked={item ? item.is_purchased : true} />Purchased</label>
      <label className="check"><input type="checkbox" name="is_sold" defaultChecked={item ? item.is_sold : true} />Sold</label>
    </div>
  );
}
