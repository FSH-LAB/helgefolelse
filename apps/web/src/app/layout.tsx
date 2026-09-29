import type { Metadata } from "next";
import { Bricolage_Grotesque } from "next/font/google";
import "./globals.css";

const bricolage = Bricolage_Grotesque({
  variable: "--font-display",
  subsets: ["latin"],
  display: "swap",
  axes: ["opsz", "wdth"],
});

export const metadata: Metadata = {
  title: "helgefølelse",
  description:
    "Hvor dypt står du i helgen? Et levende tidevann gjennom arbeidsuken. How deep are you standing in the weekend? A live tide through the working week.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="nb" className={bricolage.variable}>
      <body>{children}</body>
    </html>
  );
}
