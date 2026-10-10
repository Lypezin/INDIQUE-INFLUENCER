import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Indique e Ganhe | Portal do Influenciador",
  description: "Acompanhe suas indicações, corridas e prêmios liberados.",
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="pt-BR" data-theme="dark">
      <body className="antialiased">{children}</body>
    </html>
  );
}
