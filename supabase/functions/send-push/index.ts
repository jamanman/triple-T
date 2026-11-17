// Supabase Edge Function: send-push
//
// Sends Web Push notifications for new activity-feed events.
//   - Called by a Database Webhook on INSERT into public.events with
//     { type: 'INSERT', record: { id, ... } }. Only the id is trusted: the
//     database decides the message and recipients (push_job), and hands out
//     each event only once.
//   - Called by the app with { init: true } to create the VAPID key pair on
//     first use; returns { publicKey }.
//
// Self-contained (no imports) so it can be pasted into the Supabase dashboard
// editor. Implements RFC 8291 (message encryption, aes128gcm) and RFC 8292
// (VAPID) with WebCrypto.
//
// Deploy with "Enforce JWT verification" turned OFF (see README).

// ---------------------------------------------------------------- encoding

const te = new TextEncoder()

/** Bytes backed by a plain ArrayBuffer (what WebCrypto and fetch accept). */
type Bytes = Uint8Array<ArrayBuffer>

export function b64uEncode(bytes: Uint8Array): string {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function b64uDecode(s: string): Bytes {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

function concat(...parts: Uint8Array[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) { out.set(p, o); o += p.length }
  return out
}

async function hkdf(salt: Bytes, ikm: Bytes, info: Bytes, length: number): Promise<Bytes> {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, length * 8))
}

// ---------------------------------------------------------------- RFC 8291

/**
 * Encrypt a push message for one subscription (aes128gcm, single record).
 * `asKeys` and `salt` are only passed in tests; normally they're random.
 */
export async function encryptPayload(
  plaintext: Bytes,
  uaPublicB64: string,
  authSecretB64: string,
  opts: { asKeys?: CryptoKeyPair; salt?: Bytes } = {},
): Promise<Bytes> {
  const uaPublic = b64uDecode(uaPublicB64)
  const authSecret = b64uDecode(authSecretB64)
  const salt = opts.salt ?? crypto.getRandomValues(new Uint8Array(16))
  const as = opts.asKeys ??
    (await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair)
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', as.publicKey))

  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, as.privateKey, 256))

  const ikm = await hkdf(authSecret, ecdhSecret, concat(te.encode('WebPush: info\0'), uaPublic, asPublic), 32)
  const cek = await hkdf(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(salt, ikm, te.encode('Content-Encoding: nonce\0'), 12)

  const aesKey = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt'])
  const padded = concat(plaintext, new Uint8Array([2])) // 0x02 = last (only) record
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aesKey, padded))

  const header = new Uint8Array(16 + 4 + 1 + asPublic.length)
  header.set(salt, 0)
  new DataView(header.buffer).setUint32(16, 4096)
  header[20] = asPublic.length
  header.set(asPublic, 21)
  return concat(header, ciphertext)
}

// ---------------------------------------------------------------- RFC 8292

export interface Vapid {
  public_key: string // base64url, uncompressed P-256 point
  private_jwk: JsonWebKey
  subject: string // https://… or mailto:…
}

export async function generateVapid(subject: string): Promise<Vapid> {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))
  const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey)
  return { public_key: b64uEncode(raw), private_jwk: jwk, subject }
}

export async function vapidAuthorization(endpoint: string, vapid: Vapid, now = Date.now()): Promise<string> {
  const header = b64uEncode(te.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })))
  const claims = b64uEncode(te.encode(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor(now / 1000) + 12 * 3600,
    sub: vapid.subject,
  })))
  const { key_ops: _ops, ...jwk } = vapid.private_jwk
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, te.encode(`${header}.${claims}`)))
  return `vapid t=${header}.${claims}.${b64uEncode(sig)}, k=${vapid.public_key}`
}

// ---------------------------------------------------------------- sending

export interface Subscription { endpoint: string; p256dh: string; auth: string }

export async function sendPush(sub: Subscription, message: unknown, vapid: Vapid, fetchFn: typeof fetch = fetch): Promise<number> {
  const body = await encryptPayload(te.encode(JSON.stringify(message)), sub.p256dh, sub.auth)
  const res = await fetchFn(sub.endpoint, {
    method: 'POST',
    headers: {
      Authorization: await vapidAuthorization(sub.endpoint, vapid),
      'Content-Encoding': 'aes128gcm',
      'Content-Type': 'application/octet-stream',
      TTL: '86400',
      Urgency: 'high',
    },
    body,
  })
  await res.body?.cancel()
  return res.status
}

// ---------------------------------------------------------------- handler

export interface Env { url: string; serviceKey: string }

interface PushJob {
  title: string
  body: string
  url: string
  vapid: Vapid
  subscriptions: Subscription[]
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } })
}

export async function handle(req: Request, env: Env, fetchFn: typeof fetch = fetch): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405)

  const rpc = async (name: string, args: Record<string, unknown>) => {
    const headers: Record<string, string> = { apikey: env.serviceKey, 'Content-Type': 'application/json' }
    // Legacy service_role keys are JWTs; new sb_secret_ keys only go in `apikey`.
    if (env.serviceKey.startsWith('eyJ')) headers.Authorization = `Bearer ${env.serviceKey}`
    const res = await fetchFn(`${env.url}/rest/v1/rpc/${name}`, { method: 'POST', headers, body: JSON.stringify(args) })
    if (!res.ok) throw new Error(`${name} failed: ${res.status} ${await res.text()}`)
    const text = await res.text()
    return text ? JSON.parse(text) : null
  }

  let payload: { init?: boolean; record?: { id?: number } }
  try { payload = await req.json() } catch { return json({ error: 'Invalid JSON' }, 400) }

  try {
    if (payload.init) {
      const existing = await rpc('push_public_key', {}) as string | null
      if (existing) return json({ publicKey: existing })
      // Push services want a contact URL; the site's own address works.
      const origin = req.headers.get('origin')
      const subject = origin && origin.startsWith('https://') ? origin : env.url
      const vapid = await generateVapid(subject)
      const publicKey = await rpc('push_init_keys', {
        p_public_key: vapid.public_key, p_private_jwk: vapid.private_jwk, p_subject: vapid.subject,
      }) as string
      return json({ publicKey })
    }

    const id = Number(payload.record?.id)
    if (!Number.isFinite(id)) return json({ error: 'Expected a webhook payload with record.id' }, 400)
    const job = await rpc('push_job', { p_event_id: id }) as PushJob | null
    if (!job || job.subscriptions.length === 0) return json({ sent: 0 })

    const message = { title: job.title, body: job.body, url: job.url }
    const results = await Promise.allSettled(job.subscriptions.map((s) => sendPush(s, message, job.vapid, fetchFn)))
    // 404/410 mean the subscription is gone (uninstalled, permission revoked…).
    const gone = job.subscriptions.filter((_, i) => {
      const r = results[i]
      return r.status === 'fulfilled' && (r.value === 404 || r.value === 410)
    }).map((s) => s.endpoint)
    if (gone.length) await rpc('push_remove_subscriptions', { p_endpoints: gone })
    const sent = results.filter((r) => r.status === 'fulfilled' && r.value >= 200 && r.value < 300).length
    return json({ sent, removed: gone.length, failed: job.subscriptions.length - sent - gone.length })
  } catch (e) {
    console.error(e)
    return json({ error: (e as Error).message }, 500)
  }
}

// Only start the server when running on Supabase (Deno), not when imported by tests.
// deno-lint-ignore no-explicit-any
const deno = (globalThis as any).Deno
if (deno?.serve && !deno.env.get('SEND_PUSH_TEST')) {
  const env: Env = {
    url: deno.env.get('SUPABASE_URL'),
    serviceKey: deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? deno.env.get('SUPABASE_SECRET_KEY'),
  }
  deno.serve((req: Request) => handle(req, env))
}
