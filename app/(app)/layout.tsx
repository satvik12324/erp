import { getContext } from "@/lib/context";
import { CompanySwitcher } from "@/components/CompanySwitcher";
import { NavLink } from "@/components/NavLink";
import { signOut } from "@/app/login/actions";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { companies, company, profile, user } = await getContext();

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="brand">TOC ERP</div>
        <nav>
          <NavLink href="/">Home</NavLink>
          <div className="nav-group">TOC</div>
          <NavLink href="/sales/board">Order board</NavLink>
          <NavLink href="/sales/full-kit">Full kit</NavLink>
          <NavLink href="/buffers">Buffer board</NavLink>
          <NavLink href="/replenishment">Replenishment</NavLink>
          <NavLink href="/buffers/dbm">Buffer changes</NavLink>
          <NavLink href="/buffers/reasons">Red/black causes</NavLink>
          <div className="nav-group">Sales</div>
          <NavLink href="/sales">Sales orders</NavLink>
          <div className="nav-group">Inventory</div>
          <NavLink href="/inventory">Documents</NavLink>
          <NavLink href="/stock">Stock on hand</NavLink>
          <div className="nav-group">Purchasing</div>
          <NavLink href="/purchasing">Purchase orders</NavLink>
          <NavLink href="/purchasing/open">Open PO lines</NavLink>
          <NavLink href="/purchasing/lead-times">Lead times</NavLink>
          <NavLink href="/partners">Business partners</NavLink>
          <div className="nav-group">Item master</div>
          <NavLink href="/items">Items</NavLink>
          <NavLink href="/setup/item-groups">Item groups</NavLink>
          <NavLink href="/setup/attributes">Attributes</NavLink>
          <NavLink href="/setup/uoms">Units of measure</NavLink>
          <div className="nav-group">Setup</div>
          <NavLink href="/setup/company">Company</NavLink>
          <NavLink href="/setup/warehouses">Warehouses</NavLink>
          <NavLink href="/setup/exchange-rates">Exchange rates</NavLink>
          <NavLink href="/setup/numbering">Numbering &amp; doc types</NavLink>
          <NavLink href="/setup/reasons">Reason codes</NavLink>
        </nav>
      </aside>
      <div className="main">
        <header className="topbar">
          {companies.length > 0 ? (
            <CompanySwitcher companies={companies} current={company?.id ?? null} />
          ) : (
            <span className="muted">No company assigned</span>
          )}
          <div className="spacer" />
          <span className="muted small">{profile?.display_name ?? user.email}</span>
          <form action={signOut}>
            <button type="submit" className="link">Sign out</button>
          </form>
        </header>
        <div className="content">{children}</div>
      </div>
    </div>
  );
}
