import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-nexlab-worker-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });

const escapeHtml = (value: unknown) =>
  String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const workerSecret = Deno.env.get("NEXLAB_WORKER_SECRET") ?? "";
const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? "";
const fromEmail = Deno.env.get("NOTIFICATION_FROM_EMAIL") ?? "";
const appUrl = Deno.env.get("NEXLAB_APP_URL") ?? "";
const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const vapidSubject = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type Delivery = {
  id: string;
  notification_id: string;
  recipient_id: string;
  channel: "email" | "push";
  status: "pending" | "processing" | "sent" | "failed" | "skipped";
  attempts: number;
  payload: Record<string, unknown> | null;
};

type AuthContext = {
  mode: "worker" | "user";
  userId: string | null;
};

type WorkerSettings = {
  queueStaleMinutes: number;
  maxDeliveryAttempts: number;
  batchSize: number;
};

async function authorize(req: Request): Promise<AuthContext | null> {
  const suppliedWorkerSecret = req.headers.get("x-nexlab-worker-secret") ?? "";
  if (workerSecret && suppliedWorkerSecret === workerSecret) {
    return { mode: "worker", userId: null };
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) return null;

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const {
    data: { user },
    error,
  } = await userClient.auth.getUser();

  if (error || !user) return null;
  return { mode: "user", userId: user.id };
}

async function isAdmin(userId: string | null): Promise<boolean> {
  if (!userId) return false;
  const { data, error } = await admin
    .from("profiles")
    .select("role")
    .eq("id", userId)
    .maybeSingle();
  if (error) {
    console.error("Falha ao validar Administrador:", error);
    return false;
  }
  return ["admin", "administrador"].includes(String(data?.role ?? "").toLowerCase());
}

function parseSetting(value: unknown, fallback: number, min: number, max: number) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(min, Math.min(parsed, max)) : fallback;
}

async function loadWorkerSettings(): Promise<WorkerSettings> {
  const defaults: WorkerSettings = {
    queueStaleMinutes: 10,
    maxDeliveryAttempts: 5,
    batchSize: 50,
  };

  const { data, error } = await admin
    .from("nexlab_system_settings")
    .select("setting_key,setting_value")
    .in("setting_key", [
      "queue_stale_minutes",
      "max_delivery_attempts",
      "notification_worker_batch_size",
    ]);

  if (error) {
    if (error.code !== "42P01") console.error("Falha ao carregar configurações do worker:", error);
    return defaults;
  }

  const settings = Object.fromEntries((data ?? []).map((item) => [item.setting_key, item.setting_value]));
  return {
    queueStaleMinutes: parseSetting(settings.queue_stale_minutes, 10, 1, 1440),
    maxDeliveryAttempts: parseSetting(settings.max_delivery_attempts, 5, 1, 20),
    batchSize: parseSetting(settings.notification_worker_batch_size, 50, 1, 200),
  };
}

async function recordSystemEvent(
  eventType: string,
  severity: "info" | "warning" | "error" | "success",
  message: string,
  details: Record<string, unknown>,
) {
  const { error } = await admin.from("nexlab_system_events").insert({
    event_type: eventType,
    severity,
    message,
    details,
    actor_id: null,
  });
  if (error && error.code !== "42P01") console.error("Falha ao registrar evento técnico:", error);
}

function deliveryUrl(payload: Record<string, unknown>) {
  const targetTab = String(payload.target_tab ?? "notificacoes");
  if (!appUrl) return "";
  try {
    const url = new URL(appUrl);
    url.searchParams.set("nexlabTab", targetTab);
    const notificationId = String(payload.notification_id ?? "");
    if (notificationId) url.searchParams.set("notification", notificationId);
    return url.toString();
  } catch {
    return appUrl;
  }
}

async function sendEmail(delivery: Delivery) {
  if (!resendApiKey || !fromEmail) {
    return {
      status: "skipped" as const,
      error: "Canal de e-mail não configurado na Edge Function.",
      providerMessageId: null,
    };
  }

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("id,nome,email,ativo")
    .eq("id", delivery.recipient_id)
    .maybeSingle();

  if (profileError) throw profileError;
  if (!profile?.email || profile.ativo === false) {
    return {
      status: "skipped" as const,
      error: "Destinatário sem e-mail ativo.",
      providerMessageId: null,
    };
  }

  const payload = delivery.payload ?? {};
  const title = String(payload.title ?? "Notificação do NexLab");
  const message = String(payload.message ?? "Você recebeu uma nova notificação.");
  const emailSubject = String(payload.email_subject ?? `[NexLab] ${title}`).trim() || `[NexLab] ${title}`;
  const url = deliveryUrl(payload);
  const priority = String(payload.priority ?? "normal");

  const html = `<!doctype html>
<html lang="pt-BR">
  <body style="margin:0;background:#f4f6f8;font-family:Arial,Helvetica,sans-serif;color:#0f172a">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px;background:#f4f6f8">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:620px;background:#ffffff;border:1px solid #e2e8f0;border-radius:20px;overflow:hidden">
          <tr><td style="background:#0B2A63;padding:22px 26px;color:#ffffff">
            <div style="font-size:22px;font-weight:800">Nex<span style="color:#FF7A22">Lab</span></div>
            <div style="font-size:12px;opacity:.75;margin-top:3px">Coworking Space UEMA Timon</div>
          </td></tr>
          <tr><td style="padding:28px 26px">
            <div style="display:inline-block;padding:5px 9px;border-radius:999px;background:${priority === "urgente" || priority === "alta" ? "#fff1f2" : "#f1f5f9"};color:${priority === "urgente" || priority === "alta" ? "#be123c" : "#475569"};font-size:11px;font-weight:700;text-transform:uppercase">${escapeHtml(priority)}</div>
            <h1 style="font-size:20px;line-height:1.3;margin:16px 0 10px">${escapeHtml(title)}</h1>
            <p style="font-size:14px;line-height:1.7;color:#475569;margin:0">${escapeHtml(message)}</p>
            ${
              url
                ? `<p style="margin:24px 0 0"><a href="${escapeHtml(url)}" style="display:inline-block;background:#FF7A22;color:#ffffff;text-decoration:none;font-size:13px;font-weight:700;padding:12px 18px;border-radius:12px">Abrir no NexLab</a></p>`
                : ""
            }
          </td></tr>
          <tr><td style="padding:16px 26px;border-top:1px solid #e2e8f0;color:#94a3b8;font-size:11px">Mensagem automática. Ajuste seus canais na Central de Notificações.</td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromEmail,
      to: [profile.email],
      subject: emailSubject,
      html,
    }),
  });

  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(
      `Resend ${response.status}: ${String(result?.message ?? result?.error ?? "Falha ao enviar e-mail")}`,
    );
  }

  return {
    status: "sent" as const,
    error: null,
    providerMessageId: String(result?.id ?? "") || null,
  };
}

async function sendPush(delivery: Delivery) {
  if (!vapidPublicKey || !vapidPrivateKey || !vapidSubject) {
    return {
      status: "skipped" as const,
      error: "Canal Web Push não configurado na Edge Function.",
      providerMessageId: null,
    };
  }

  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);

  const { data: subscriptions, error } = await admin
    .from("push_subscriptions")
    .select("id,endpoint,p256dh,auth,expiration_time")
    .eq("user_id", delivery.recipient_id)
    .eq("active", true);

  if (error) throw error;
  if (!subscriptions?.length) {
    return {
      status: "skipped" as const,
      error: "Nenhum dispositivo push ativo.",
      providerMessageId: null,
    };
  }

  const payload = delivery.payload ?? {};
  const notificationPayload = JSON.stringify({
    title: String(payload.title ?? "NexLab"),
    body: String(payload.message ?? "Você recebeu uma nova notificação."),
    icon: "./icons/nexlab-192.png",
    badge: "./icons/nexlab-192.png",
    tag: `nexlab-${String(payload.notification_id ?? delivery.notification_id)}`,
    data: {
      url: deliveryUrl(payload),
      targetTab: String(payload.target_tab ?? "notificacoes"),
      notificationId: String(payload.notification_id ?? delivery.notification_id),
    },
  });

  let sent = 0;
  const failures: string[] = [];

  for (const subscription of subscriptions) {
    try {
      await webpush.sendNotification(
        {
          endpoint: subscription.endpoint,
          expirationTime: subscription.expiration_time ?? null,
          keys: { p256dh: subscription.p256dh, auth: subscription.auth },
        },
        notificationPayload,
        { TTL: 60 * 60, urgency: "normal" },
      );
      sent += 1;
    } catch (error) {
      const statusCode = Number((error as { statusCode?: number })?.statusCode ?? 0);
      const message = error instanceof Error ? error.message : String(error);
      failures.push(message);

      if (statusCode === 404 || statusCode === 410) {
        await admin
          .from("push_subscriptions")
          .update({ active: false, updated_at: new Date().toISOString() })
          .eq("id", subscription.id);
      }
    }
  }

  if (sent === 0) {
    throw new Error(failures[0] ?? "Nenhum dispositivo aceitou a notificação push.");
  }

  return {
    status: "sent" as const,
    error: failures.length ? `${failures.length} dispositivo(s) falharam.` : null,
    providerMessageId: `push:${sent}`,
  };
}

async function claimDelivery(delivery: Delivery) {
  const attempts = Number(delivery.attempts ?? 0) + 1;
  const { data, error } = await admin
    .from("notification_deliveries")
    .update({
      status: "processing",
      attempts,
      claimed_at: new Date().toISOString(),
      last_error: null,
    })
    .eq("id", delivery.id)
    .eq("status", "pending")
    .select("id")
    .maybeSingle();

  if (error) throw error;
  return data ? attempts : null;
}

async function completeDelivery(
  delivery: Delivery,
  result: { status: "sent" | "skipped"; error: string | null; providerMessageId: string | null },
) {
  const { error } = await admin
    .from("notification_deliveries")
    .update({
      status: result.status,
      sent_at: result.status === "sent" ? new Date().toISOString() : null,
      provider_message_id: result.providerMessageId,
      last_error: result.error,
      claimed_at: null,
    })
    .eq("id", delivery.id);
  if (error) throw error;
}

async function failDelivery(
  delivery: Delivery,
  attempts: number,
  error: unknown,
  maxDeliveryAttempts: number,
) {
  const message = error instanceof Error ? error.message : String(error);
  const terminal = attempts >= maxDeliveryAttempts;
  const delayMinutes = Math.min(60, Math.max(1, 2 ** Math.max(0, attempts - 1)));
  const nextAttemptAt = new Date(Date.now() + delayMinutes * 60_000).toISOString();

  const { error: updateError } = await admin
    .from("notification_deliveries")
    .update({
      status: terminal ? "failed" : "pending",
      next_attempt_at: nextAttemptAt,
      last_error: message.slice(0, 1800),
      claimed_at: null,
    })
    .eq("id", delivery.id);

  if (updateError) console.error("Falha ao registrar erro de entrega:", updateError);
}

async function resetStaleClaims(staleMinutes: number) {
  const staleTime = new Date(Date.now() - staleMinutes * 60_000).toISOString();
  const { error } = await admin
    .from("notification_deliveries")
    .update({ status: "pending", claimed_at: null, next_attempt_at: new Date().toISOString() })
    .eq("status", "processing")
    .lt("claimed_at", staleTime);
  if (error) throw error;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Método não permitido." }, 405);

  const auth = await authorize(req);
  if (!auth) return json({ error: "Não autorizado." }, 401);

  const body = await req.json().catch(() => ({}));
  const action = String(body?.action ?? "process");
  const settings = await loadWorkerSettings();
  const adminAccess = auth.mode === "worker" || (auth.userId ? await isAdmin(auth.userId) : false);

  if (action === "health") {
    return json({
      ok: true,
      version: "25.9.0",
      emailConfigured: Boolean(resendApiKey && fromEmail),
      pushConfigured: Boolean(vapidPublicKey && vapidPrivateKey && vapidSubject),
      appUrlConfigured: Boolean(appUrl),
      workerSettings: settings,
      adminAccess,
      checkedAt: new Date().toISOString(),
    });
  }

  if (action === "admin_process" && !adminAccess) {
    return json({ error: "Apenas o Administrador pode processar toda a fila." }, 403);
  }

  await resetStaleClaims(settings.queueStaleMinutes);

  const processGlobally = auth.mode === "worker" || action === "admin_process";
  let query = admin
    .from("notification_deliveries")
    .select("id,notification_id,recipient_id,channel,status,attempts,payload")
    .eq("status", "pending")
    .lte("next_attempt_at", new Date().toISOString())
    .order("created_at", { ascending: true })
    .limit(processGlobally ? settings.batchSize : Math.min(settings.batchSize, 12));

  if (!processGlobally && auth.userId) query = query.eq("recipient_id", auth.userId);

  const { data: deliveries, error } = await query;
  if (error) return json({ error: error.message }, 500);

  const stats = { selected: deliveries?.length ?? 0, sent: 0, skipped: 0, failed: 0 };

  for (const delivery of (deliveries ?? []) as Delivery[]) {
    const attempts = await claimDelivery(delivery).catch((claimError) => {
      console.error("Falha ao reservar entrega:", claimError);
      return null;
    });
    if (attempts === null) continue;

    try {
      const result = delivery.channel === "email" ? await sendEmail(delivery) : await sendPush(delivery);
      await completeDelivery(delivery, result);
      if (result.status === "sent") stats.sent += 1;
      else stats.skipped += 1;
    } catch (deliveryError) {
      console.error(`Entrega ${delivery.id} falhou:`, deliveryError);
      await failDelivery(delivery, attempts, deliveryError, settings.maxDeliveryAttempts);
      stats.failed += 1;
    }

    await sleep(40);
  }

  if (processGlobally && stats.selected > 0) {
    await recordSystemEvent(
      "notification_worker_run",
      stats.failed > 0 ? "warning" : "success",
      "Worker de notificações executado.",
      { action, mode: auth.mode, ...stats },
    );
  }

  return json({ ok: true, mode: auth.mode, global: processGlobally, settings, ...stats });
});
