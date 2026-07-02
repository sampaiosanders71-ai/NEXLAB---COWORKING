import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const envPath = path.join(root, ".env");

function readEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return {};
  return Object.fromEntries(
    fs
      .readFileSync(filePath, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#") && line.includes("="))
      .map((line) => {
        const separator = line.indexOf("=");
        const key = line.slice(0, separator).trim();
        const value = line
          .slice(separator + 1)
          .trim()
          .replace(/^['"]|['"]$/g, "");
        return [key, value];
      }),
  );
}

const fileEnv = readEnvFile(envPath);
const supabaseUrl =
  process.env.VITE_SUPABASE_URL ||
  fileEnv.VITE_SUPABASE_URL ||
  "https://eahldhabwulnwhuwrhvc.supabase.co";
const supabaseAnonKey =
  process.env.VITE_SUPABASE_ANON_KEY ||
  fileEnv.VITE_SUPABASE_ANON_KEY ||
  "sb_publishable_hr-WTQUBbBE0Ei3Lr2hkhQ_XSKG_PXa";
const vapidPublicKey =
  process.env.VITE_VAPID_PUBLIC_KEY ||
  fileEnv.VITE_VAPID_PUBLIC_KEY ||
  "BC-C9g9bRHzNTrffU4ffaG_z2iay3zO16Xe4bL93k6JTT2Z2OlJm3q4RR_Rjt8vkSAnG92B4_3s2rHT9DiDVb40";
const appUrl =
  process.env.VITE_APP_URL ||
  fileEnv.VITE_APP_URL ||
  "";

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error("VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY são obrigatórias.");
}

const config = `globalThis.__NEXLAB_CONFIG__ = ${JSON.stringify(
  { supabaseUrl, supabaseAnonKey, vapidPublicKey, appUrl },
  null,
  2,
)};\n`;

fs.mkdirSync(path.join(root, "src"), { recursive: true });
fs.writeFileSync(path.join(root, "src", "config.js"), config, "utf8");
console.log("Configuração pública do Supabase gerada em src/config.js.");
