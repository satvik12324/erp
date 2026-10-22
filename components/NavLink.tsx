"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function NavLink({ href, children }: { href: string; children: React.ReactNode }) {
  const path = usePathname();
  const exact = href === "/" || href === "/purchasing";
  const active = exact ? path === href || (href === "/purchasing" && /^\/purchasing\/(new|[0-9a-f-]{36})/.test(path)) : path === href || path.startsWith(href + "/");
  return (
    <Link href={href} className={active ? "nav-link active" : "nav-link"}>
      {children}
    </Link>
  );
}
