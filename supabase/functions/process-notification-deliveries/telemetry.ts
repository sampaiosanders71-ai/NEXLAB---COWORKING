export async function saveProviderHealth(client: any, channel: string, provider: string, configured: boolean, valid: boolean, operational: boolean, status: string, details: Record<string, unknown>) {
  const now = new Date().toISOString();
  await client.from("nexlab_notification_provider_health").upsert({ channel, provider, configured, valid, operational, status, details, checked_at: now, updated_at: now }, { onConflict: "channel" });
}

export async function providerSnapshot(client: any) {
  const { data } = await client.from("nexlab_notification_provider_health").select("channel,provider,configured,valid,operational,status,details,checked_at").order("channel");
  return data ?? [];
}

export async function queueSnapshot(client: any) {
  const { data } = await client.from("notification_deliveries").select("status,next_attempt_at,terminal_at").eq("channel", "push");
  const rows = data ?? [];
  const now = Date.now();
  return {
    total: rows.length,
    pending: rows.filter((row: any) => row.status === "pending").length,
    due: rows.filter((row: any) => row.status === "pending" && new Date(row.next_attempt_at).getTime() <= now).length,
    processing: rows.filter((row: any) => row.status === "processing").length,
    sent: rows.filter((row: any) => row.status === "sent").length,
    skipped: rows.filter((row: any) => row.status === "skipped").length,
    failed: rows.filter((row: any) => row.status === "failed").length,
    terminal: rows.filter((row: any) => Boolean(row.terminal_at)).length,
  };
}

export async function beginRun(client: any, source: string, action: string, runtimeVersion: string, edgeVersion: number) {
  const { data, error } = await client.from("nexlab_notification_worker_runs").insert({
    source,
    action,
    runtime_version: runtimeVersion,
    edge_version: edgeVersion,
    status: "running",
    queue_before: await queueSnapshot(client),
    provider_snapshot: await providerSnapshot(client),
  }).select("id").single();
  if (error) throw error;
  return String(data.id);
}

export async function finishRun(client: any, runId: string, status: string, stats: Record<string, number>, errorMessage: string | null = null) {
  await client.from("nexlab_notification_worker_runs").update({
    status,
    finished_at: new Date().toISOString(),
    http_status: status === "failed" ? 500 : 200,
    selected_count: stats.selected ?? 0,
    sent_count: stats.sent ?? 0,
    skipped_count: stats.skipped ?? 0,
    retry_count: stats.retried ?? 0,
    terminal_count: stats.terminal ?? 0,
    overdue_count: stats.overdueDetected ?? 0,
    queue_after: await queueSnapshot(client),
    provider_snapshot: await providerSnapshot(client),
    error_message: errorMessage,
  }).eq("id", runId);
}

export async function createAttempt(client: any, deliveryId: string, runId: string, attemptNumber: number) {
  const { data, error } = await client.from("notification_delivery_attempts").insert({
    delivery_id: deliveryId,
    worker_run_id: runId,
    attempt_number: attemptNumber,
    outcome: "processing",
    provider: "web-push",
  }).select("id").single();
  if (error) throw error;
  return String(data.id);
}

export async function finishAttempt(client: any, attemptId: string, values: Record<string, unknown>) {
  await client.from("notification_delivery_attempts").update({ ...values, finished_at: new Date().toISOString() }).eq("id", attemptId);
}
