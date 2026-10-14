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
    <html lang="pt-BR" data-theme="light" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: `try{var savedTheme=localStorage.getItem("indique-ganhe:theme:v2");if(savedTheme==="dark"){document.documentElement.dataset.theme="dark";document.documentElement.style.colorScheme="dark"}}catch{}` }} />
      </head>
      <body className="antialiased">{children}</body>
    </html>
  );
}
