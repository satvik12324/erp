"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function NavLink({ href, children }: { href: string; children: React.ReactNode }) {
  const path = usePathname();
  // Section roots whose sub-pages have their own nav entries match only themselves and their documents.
  const roots = ["/purchasing", "/sales", "/buffers"];
  const docOf = (root: string) => new RegExp(`^${root}/(new|[0-9a-f-]{36})`).test(path);
  const active =
    href === "/" ? path === "/" : roots.includes(href) ? path === href || docOf(href) : path === href || path.startsWith(href + "/");
  return (
    <Link href={href} className={active ? "nav-link active" : "nav-link"}>
      {children}
    </Link>
  );
}
