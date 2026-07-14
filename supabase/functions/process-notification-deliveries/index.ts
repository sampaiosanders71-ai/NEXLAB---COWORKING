import { createClient } from "npm:@supabase/supabase-js@2";
import { inspectVapid } from "./vapid.ts";
import { beginRun, finishRun, saveProviderHealth } from "./telemetry.ts";
import { loadSettings, processQueue } from "./worker.ts";

const VERSION = "26.17.4";
const EDGE_VERSION = 16;
const EMAIL_MODE = "suspended";
const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const appUrl = Deno.env.get("NEXLAB_APP_URL") ?? "";
const publicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const privateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const vapidSubject = (Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com").trim();
const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
const vapid = inspectVapid(publicKey, privateKey, vapidSubject);

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...headers, "Content-Type": "application/json; charset=utf-8" } });

async function consumeInvocation(id: string) {
  if (!id) return false;
  const { data, error } = await admin.from("nexlab_worker_invocations").update({ used_at: new Date().toISOString() })
    .eq("id", id).eq("worker_name", "notification-delivery-worker").is("used_at", null)
    .gt("expires_at", new Date().toISOString()).select("id").maybeSingle();
  return !error && Boolean(data);
}

async function authorize(request: Request, body: Record<string, unknown>) {
  if (await consumeInvocation(String(body.invocation_id ?? ""))) return { mode: "worker", userId: null, admin: true };
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) return null;
  const client = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: { user }, error } = await client.auth.getUser();
  if (error || !user) return null;
  const { data: profile } = await admin.from("profiles").select("role,ativo").eq("id", user.id).maybeSingle();
  if (!profile || profile.ativo === false) return null;
  return { mode: "user", userId: user.id, admin: ["admin", "administrador"].includes(String(profile.role ?? "").toLowerCase()) };
}

async function updateProviderHealth() {
  await saveProviderHealth(admin, "push", "web-push", vapid.configured, vapid.valid, false,
    !vapid.configured ? "not_configured" : vapid.valid ? "configured" : "invalid",
    { publicBytes: vapid.publicBytes, privateBytes: vapid.privateBytes, publicFormat: vapid.publicFormat, privateFormat: vapid.privateFormat, pairMatches: vapid.pairMatches, reason: vapid.reason });
  await saveProviderHealth(admin, "email", "none", false, true, false, "suspended",
    { reason: "Canal suspenso por decisão administrativa.", affects_readiness: false, external_channel_active: false });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers });
  if (request.method !== "POST") return response({ error: "Método não permitido." }, 405);

  const body = await request.json().catch(() => ({})) as Record<string, unknown>;
  const auth = await authorize(request, body);
  if (!auth) return response({ error: "Não autorizado." }, 401);

  const action = String(body.action ?? "process");
  const settings = await loadSettings(admin);
  await updateProviderHealth();

  if (action === "health") {
    if (!auth.admin) return response({ error: "Apenas Administradores podem consultar o diagnóstico." }, 403);
    return response({
      ok: true,
      version: VERSION,
      edgeVersion: EDGE_VERSION,
      emailMode: EMAIL_MODE,
      providers: {
        push: { configured: vapid.configured, valid: vapid.valid, pairMatches: vapid.pairMatches, publicBytes: vapid.publicBytes, privateBytes: vapid.privateBytes, publicFormat: vapid.publicFormat, privateFormat: vapid.privateFormat, reason: vapid.reason },
        email: { status: "suspended", configured: false, operational: false, affectsReadiness: false },
      },
      settings,
      checkedAt: new Date().toISOString(),
    });
  }

  if (action === "admin_process" && !auth.admin) return response({ error: "Apenas Administradores podem processar toda a fila." }, 403);

  let runId = "";
  try {
    runId = await beginRun(admin, auth.mode, action, VERSION, EDGE_VERSION);
    const result = await processQueue(admin, auth, settings, runId, vapid, vapidSubject, appUrl);
    const degraded = result.providerBlocked || result.retried > 0 || result.terminal > 0;
    await finishRun(admin, runId, degraded ? "degraded" : "success", {
      selected: result.selected,
      sent: result.sent,
      skipped: result.skipped,
      retried: result.retried,
      terminal: result.terminal,
      overdueDetected: result.overdueDetected,
    }, result.providerError);

    if (auth.mode === "worker" || auth.admin) {
      await admin.from("nexlab_system_events").insert({
        event_type: "notification_worker_run",
        severity: degraded ? "warning" : "success",
        message: result.providerBlocked ? "Worker executado, mas o Web Push está bloqueado pelo provedor." : "Worker de notificações executado com telemetria persistente.",
        details: { version: VERSION, edgeVersion: EDGE_VERSION, runId, emailMode: EMAIL_MODE, ...result },
        actor_id: auth.userId,
      });
    }

    return response({ ok: true, version: VERSION, edgeVersion: EDGE_VERSION, runId, mode: auth.mode, emailMode: EMAIL_MODE, settings, ...result });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (runId) await finishRun(admin, runId, "failed", {}, message);
    return response({ ok: false, version: VERSION, edgeVersion: EDGE_VERSION, runId: runId || null, error: message }, 500);
  }
});
