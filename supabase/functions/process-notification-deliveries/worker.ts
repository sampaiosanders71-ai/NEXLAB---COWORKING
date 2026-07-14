import { sendWebPush, type VapidState } from "./vapid.ts";
import { createAttempt, finishAttempt } from "./telemetry.ts";

export type WorkerSettings = { stale: number; attempts: number; batch: number; overdue: number; retryBase: number; retryMax: number };

export async function loadSettings(client: any): Promise<WorkerSettings> {
  const { data } = await client.from("nexlab_system_settings").select("setting_key,setting_value").in("setting_key", [
    "queue_stale_minutes", "max_delivery_attempts", "notification_worker_batch_size",
    "notification_pending_overdue_minutes", "notification_retry_base_minutes", "notification_retry_max_minutes",
  ]);
  const values = Object.fromEntries((data ?? []).map((item: any) => [item.setting_key, Number(item.setting_value)]));
  const limit = (value: number, fallback: number, min: number, max: number) => Number.isFinite(value) ? Math.max(min, Math.min(value, max)) : fallback;
  return {
    stale: limit(values.queue_stale_minutes, 10, 1, 1440),
    attempts: limit(values.max_delivery_attempts, 5, 1, 20),
    batch: limit(values.notification_worker_batch_size, 50, 1, 200),
    overdue: limit(values.notification_pending_overdue_minutes, 15, 1, 10080),
    retryBase: limit(values.notification_retry_base_minutes, 2, 1, 60),
    retryMax: limit(values.notification_retry_max_minutes, 60, 1, 1440),
  };
}

async function markOverdue(client: any, minutes: number) {
  const { data, error } = await client.from("notification_deliveries")
    .update({ overdue_detected_at: new Date().toISOString() })
    .eq("channel", "push").eq("status", "pending")
    .lte("next_attempt_at", new Date().toISOString())
    .lt("created_at", new Date(Date.now() - minutes * 60000).toISOString())
    .is("overdue_detected_at", null).select("id");
  if (error) throw error;
  return data?.length ?? 0;
}

async function terminalizeExhausted(client: any, settings: WorkerSettings, runId: string) {
  const now = new Date().toISOString();
  const { data, error } = await client.from("notification_deliveries").update({
    status: "failed",
    terminal_at: now,
    terminal_reason: `Limite definitivo de ${settings.attempts} tentativas atingido.`,
    last_attempt_outcome: "terminal",
    last_worker_run_id: runId,
    claimed_at: null,
  }).eq("channel", "push").in("status", ["pending", "processing"]).gte("attempts", settings.attempts).select("id");
  if (error) throw error;
  return data?.length ?? 0;
}

export async function processQueue(client: any, auth: any, settings: WorkerSettings, runId: string, vapid: VapidState, vapidSubject: string, appUrl: string) {
  await client.from("notification_deliveries").update({ status: "pending", claimed_at: null, next_attempt_at: new Date().toISOString() })
    .eq("channel", "push").eq("status", "processing")
    .lt("claimed_at", new Date(Date.now() - settings.stale * 60000).toISOString())
    .lt("attempts", settings.attempts);

  const stats = {
    selected: 0,
    sent: 0,
    skipped: 0,
    retried: 0,
    terminal: await terminalizeExhausted(client, settings, runId),
    overdueDetected: await markOverdue(client, settings.overdue),
  };

  if (!vapid.valid) return { ...stats, providerBlocked: true, providerError: vapid.reason ?? "Par VAPID inválido." };

  let query = client.from("notification_deliveries").select("id,notification_id,recipient_id,channel,attempts,payload")
    .eq("channel", "push").eq("status", "pending").lt("attempts", settings.attempts)
    .lte("next_attempt_at", new Date().toISOString()).order("created_at", { ascending: true })
    .limit(auth.mode === "worker" || auth.admin ? settings.batch : Math.min(settings.batch, 12));
  if (auth.mode === "user" && !auth.admin && auth.userId) query = query.eq("recipient_id", auth.userId);

  const { data, error } = await query;
  if (error) throw error;
  stats.selected = data?.length ?? 0;

  for (const delivery of data ?? []) {
    const attemptNumber = Number(delivery.attempts ?? 0) + 1;
    const attemptTime = new Date().toISOString();
    const { data: claimed } = await client.from("notification_deliveries").update({
      status: "processing", attempts: attemptNumber, claimed_at: attemptTime,
      last_attempt_at: attemptTime, last_error: null, last_worker_run_id: runId,
    }).eq("id", delivery.id).eq("status", "pending").select("id").maybeSingle();
    if (!claimed) continue;

    const attemptId = await createAttempt(client, delivery.id, runId, attemptNumber);
    try {
      const result = await sendWebPush(client, vapid, vapidSubject, appUrl, delivery);
      const finishedAt = new Date().toISOString();
      await client.from("notification_deliveries").update({
        status: result.status,
        sent_at: result.status === "sent" ? finishedAt : null,
        provider_message_id: result.providerId,
        last_error: result.reason,
        last_provider_status: result.providerStatus,
        last_attempt_outcome: result.status,
        terminal_at: finishedAt,
        terminal_reason: result.status === "skipped" ? result.reason : null,
        claimed_at: null,
        updated_at: finishedAt,
      }).eq("id", delivery.id);
      await finishAttempt(client, attemptId, {
        outcome: result.status,
        provider_http_status: result.providerStatus,
        provider_message_id: result.providerId,
        error_message: result.reason,
        metadata: result.metadata,
      });
      if (result.status === "sent") stats.sent += 1;
      else stats.skipped += 1;
    } catch (error) {
      const failure = error as any;
      const terminal = Boolean(failure.permanent) || attemptNumber >= settings.attempts;
      const retryMinutes = Math.min(settings.retryMax, settings.retryBase * (2 ** Math.max(0, attemptNumber - 1)));
      const message = String(failure.message ?? error).slice(0, 1800);
      const finishedAt = new Date().toISOString();
      await client.from("notification_deliveries").update({
        status: terminal ? "failed" : "pending",
        next_attempt_at: terminal ? new Date(Date.now() + 365 * 24 * 60 * 60000).toISOString() : new Date(Date.now() + retryMinutes * 60000).toISOString(),
        last_error: message,
        last_provider_status: failure.statusCode ?? null,
        last_attempt_outcome: terminal ? "terminal" : "retry",
        terminal_at: terminal ? finishedAt : null,
        terminal_reason: terminal ? message : null,
        claimed_at: null,
        updated_at: finishedAt,
      }).eq("id", delivery.id);
      await finishAttempt(client, attemptId, {
        outcome: terminal ? "terminal" : "retry",
        provider_http_status: failure.statusCode ?? null,
        error_code: failure.errorCode ?? "DELIVERY_ERROR",
        error_message: message,
        metadata: failure.metadata ?? {},
      });
      if (terminal) stats.terminal += 1;
      else stats.retried += 1;
    }
  }

  return { ...stats, providerBlocked: false, providerError: null };
}
