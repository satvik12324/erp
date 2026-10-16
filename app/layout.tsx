import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "TOC ERP",
  description: "Inventory, BOM and TOC operations",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
