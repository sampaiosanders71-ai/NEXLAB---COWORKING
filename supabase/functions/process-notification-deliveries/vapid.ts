import webpush from "npm:web-push@3.6.7";
import { Buffer } from "node:buffer";
import { createECDH, createPrivateKey } from "node:crypto";

export type VapidState = {
  configured: boolean;
  valid: boolean;
  pairMatches: boolean;
  publicValue: string;
  privateValue: string;
  publicBytes: number;
  privateBytes: number;
  publicFormat: string;
  privateFormat: string;
  reason: string | null;
};

function unwrap(value: string): string {
  let current = String(value ?? "").trim();
  for (let index = 0; index < 4; index += 1) {
    if ((current.startsWith('"') && current.endsWith('"')) ||
        (current.startsWith("'") && current.endsWith("'"))) {
      current = current.slice(1, -1).trim();
      continue;
    }
    try {
      const parsed = JSON.parse(current);
      if (typeof parsed === "string") {
        current = parsed.trim();
        continue;
      }
    } catch {
      // Valor simples.
    }
    break;
  }
  return current;
}

function extractPrivateKey(key: string | Buffer, format: "pem" | "der", type: "pkcs8" | "sec1" = "pkcs8") {
  try {
    const object = format === "pem"
      ? createPrivateKey(key)
      : createPrivateKey({ key: key as Buffer, format: "der", type });
    const jwk = object.export({ format: "jwk" }) as { d?: string };
    const value = String(jwk.d ?? "");
    return Buffer.from(value, "base64url").length === 32 ? value : "";
  } catch {
    return "";
  }
}

function parsePrivate(input: string, depth = 0): { value: string; bytes: number; error: string | null; format: string } {
  if (depth > 5) return { value: "", bytes: 0, error: "Formato da chave privada não reconhecido.", format: "unknown" };
  const value = unwrap(input);
  if (!value) return { value: "", bytes: 0, error: "Chave privada ausente.", format: "missing" };

  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === "object") {
      const object = parsed as Record<string, unknown>;
      const candidate = object.d ?? object.privateKey ?? object.private ?? object.value;
      if (typeof candidate === "string") return parsePrivate(candidate, depth + 1);
    }
  } catch {
    // Valor simples.
  }

  if (value.includes("BEGIN")) {
    const result = extractPrivateKey(value, "pem");
    return result
      ? { value: result, bytes: 32, error: null, format: "pem" }
      : { value: "", bytes: 0, error: "Chave PEM inválida.", format: "pem" };
  }

  if (/^(?:0x)?[0-9a-fA-F]{64}$/.test(value)) {
    return {
      value: Buffer.from(value.replace(/^0x/i, ""), "hex").toString("base64url"),
      bytes: 32,
      error: null,
      format: "hex",
    };
  }

  try {
    const decoded = Buffer.from(value.replace(/\s+/g, ""), "base64url");
    if (decoded.length === 32) {
      return { value: decoded.toString("base64url"), bytes: 32, error: null, format: "base64url" };
    }
    if (decoded.length === 33 && decoded[0] === 0) {
      return { value: decoded.subarray(1).toString("base64url"), bytes: 32, error: null, format: "base64url-leading-zero" };
    }

    for (const type of ["pkcs8", "sec1"] as const) {
      const result = extractPrivateKey(decoded, "der", type);
      if (result) return { value: result, bytes: 32, error: null, format: `der-${type}` };
    }

    const decodedText = unwrap(decoded.toString("utf8"));
    const printable = decodedText.length > 0 && [...decodedText].filter((character) => {
      const code = character.charCodeAt(0);
      return code === 9 || code === 10 || code === 13 || (code >= 32 && code <= 126);
    }).length / decodedText.length > 0.95;

    if (printable && decodedText !== value) {
      const nested = parsePrivate(decodedText, depth + 1);
      if (!nested.error) return { ...nested, format: `encoded-${nested.format}` };
    }

    return {
      value: decoded.toString("base64url"),
      bytes: decoded.length,
      error: `Chave privada com ${decoded.length} bytes; esperado: 32.`,
      format: "base64url-invalid-length",
    };
  } catch (error) {
    return { value: "", bytes: 0, error: error instanceof Error ? error.message : String(error), format: "invalid" };
  }
}

function parsePublic(input: string) {
  let value = unwrap(input);
  if (!value) return { value: "", bytes: 0, error: "Chave pública ausente.", format: "missing" };
  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === "object") {
      const object = parsed as Record<string, unknown>;
      const candidate = object.publicKey ?? object.public ?? object.value;
      if (typeof candidate === "string") value = unwrap(candidate);
    }
  } catch {
    // Valor simples.
  }
  try {
    const decoded = Buffer.from(value.replace(/\s+/g, ""), "base64url");
    return decoded.length === 65
      ? { value: decoded.toString("base64url"), bytes: 65, error: null, format: "base64url" }
      : { value: decoded.toString("base64url"), bytes: decoded.length, error: `Chave pública com ${decoded.length} bytes; esperado: 65.`, format: "invalid-length" };
  } catch (error) {
    return { value: "", bytes: 0, error: error instanceof Error ? error.message : String(error), format: "invalid" };
  }
}

export function inspectVapid(publicInput: string, privateInput: string, subject: string): VapidState {
  const publicKey = parsePublic(publicInput);
  let privateKey = parsePrivate(privateInput);
  let reason = publicKey.error ?? privateKey.error;
  let pairMatches = false;

  const matchesPublicKey = (candidate: Buffer) => {
    try {
      const ecdh = createECDH("prime256v1");
      ecdh.setPrivateKey(candidate);
      return ecdh.getPublicKey(undefined, "uncompressed").toString("base64url") === publicKey.value;
    } catch {
      return false;
    }
  };

  if (!publicKey.error && privateKey.error && privateKey.value) {
    const decoded = Buffer.from(privateKey.value, "base64url");
    for (let offset = 0; offset <= decoded.length - 32; offset += 1) {
      const candidate = decoded.subarray(offset, offset + 32);
      if (matchesPublicKey(candidate)) {
        privateKey = {
          value: candidate.toString("base64url"),
          bytes: 32,
          error: null,
          format: `embedded-window-${offset}`,
        };
        reason = null;
        break;
      }
    }
  }

  if (!reason) {
    pairMatches = matchesPublicKey(Buffer.from(privateKey.value, "base64url"));
    if (!pairMatches) reason = "A chave privada não corresponde à chave pública.";
  }

  return {
    configured: Boolean(publicInput && privateInput && subject),
    valid: !reason && pairMatches,
    pairMatches,
    publicValue: publicKey.value,
    privateValue: privateKey.value,
    publicBytes: publicKey.bytes,
    privateBytes: privateKey.bytes,
    publicFormat: publicKey.format,
    privateFormat: privateKey.format,
    reason,
  };
}

export async function sendWebPush(
  client: any,
  vapid: VapidState,
  subject: string,
  appUrl: string,
  delivery: any,
) {
  if (!vapid.valid) throw Object.assign(new Error(vapid.reason ?? "Par VAPID inválido."), { errorCode: "VAPID_INVALID", permanent: false });
  webpush.setVapidDetails(subject, vapid.publicValue, vapid.privateValue);

  const { data: subscriptions, error } = await client.from("push_subscriptions")
    .select("id,endpoint,p256dh,auth,expiration_time")
    .eq("user_id", delivery.recipient_id)
    .eq("active", true);
  if (error) throw error;
  if (!subscriptions?.length) {
    return { status: "skipped", providerId: null, providerStatus: null, reason: "Nenhum dispositivo Push ativo.", metadata: { devicesAttempted: 0, devicesAccepted: 0 } };
  }

  const source = delivery.payload ?? {};
  let destination = appUrl;
  try {
    const url = new URL(appUrl);
    url.searchParams.set("nexlabTab", String(source.target_tab ?? "notificacoes"));
    if (source.notification_id) url.searchParams.set("notification", String(source.notification_id));
    destination = url.toString();
  } catch {
    // Mantém a URL original.
  }

  const payload = JSON.stringify({
    title: String(source.title ?? "NEXLAB"),
    body: String(source.message ?? "Você recebeu uma nova notificação."),
    icon: "./icons/nexlab-192.png",
    badge: "./icons/nexlab-192.png",
    tag: `nexlab-${String(source.notification_id ?? delivery.notification_id)}`,
    data: { url: destination, targetTab: String(source.target_tab ?? "notificacoes"), notificationId: String(source.notification_id ?? delivery.notification_id) },
  });

  const acceptedStatuses: number[] = [];
  const failures: Array<{ status: number; message: string }> = [];
  for (const subscription of subscriptions) {
    try {
      const response = await webpush.sendNotification({
        endpoint: subscription.endpoint,
        expirationTime: subscription.expiration_time ?? null,
        keys: { p256dh: subscription.p256dh, auth: subscription.auth },
      }, payload, { TTL: 3600, urgency: "normal" });
      const status = Number(response?.statusCode ?? 201);
      if (status >= 200 && status < 300) acceptedStatuses.push(status);
    } catch (error) {
      const status = Number((error as any)?.statusCode ?? 0);
      failures.push({ status, message: error instanceof Error ? error.message : String(error) });
      if (status === 404 || status === 410) {
        await client.from("push_subscriptions").update({ active: false }).eq("id", subscription.id);
      }
    }
  }

  if (acceptedStatuses.length > 0) {
    return {
      status: "sent",
      providerId: `webpush:${acceptedStatuses.length}:${crypto.randomUUID()}`,
      providerStatus: acceptedStatuses[0],
      reason: failures.length ? `${failures.length} dispositivo(s) rejeitaram a entrega.` : null,
      metadata: { devicesAttempted: subscriptions.length, devicesAccepted: acceptedStatuses.length, responseStatuses: acceptedStatuses, failureStatuses: failures.map((item) => item.status) },
    };
  }

  if (failures.length > 0 && failures.every((item) => item.status === 404 || item.status === 410)) {
    return { status: "skipped", providerId: null, providerStatus: failures[0]?.status ?? null, reason: "Todas as inscrições Push estavam expiradas ou removidas.", metadata: { devicesAttempted: subscriptions.length, devicesAccepted: 0, failureStatuses: failures.map((item) => item.status) } };
  }

  const first = failures[0];
  throw Object.assign(new Error(first?.message ?? "Nenhum dispositivo aceitou a notificação."), {
    statusCode: first?.status || null,
    errorCode: "PROVIDER_REJECTED",
    permanent: Boolean(first?.status && first.status >= 400 && first.status < 500 && first.status !== 408 && first.status !== 429),
    metadata: { devicesAttempted: subscriptions.length, devicesAccepted: 0, failureStatuses: failures.map((item) => item.status) },
  });
}
