// Tests for the send-push edge function. Runs on Node 22+ (type stripping) or Deno:
//   node --test supabase/functions/send-push/send-push.test.ts
//   SEND_PUSH_TEST=1 deno test supabase/functions/send-push/send-push.test.ts
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  b64uDecode, b64uEncode, encryptPayload, generateVapid, handle, vapidAuthorization, type Vapid,
} from './index.ts'

const te = new TextEncoder()
const td = new TextDecoder()

// RFC 8291 Appendix A.
const RFC = {
  plaintext: 'When I grow up, I want to be a watermelon',
  asPublic: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  asPrivate: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
  uaPublic: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
  uaPrivate: 'q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94',
  authSecret: 'BTBZMqHH6r4Tts7J_aSIgg',
  salt: 'DGv6ra1nlYgDCS1FRnbzlw',
  body: 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
}

function jwk(publicB64: string, privateB64?: string): JsonWebKey {
  const raw = b64uDecode(publicB64)
  return {
    kty: 'EC', crv: 'P-256',
    x: b64uEncode(raw.slice(1, 33)), y: b64uEncode(raw.slice(33, 65)),
    ...(privateB64 ? { d: privateB64 } : {}),
  }
}

async function ecdhPair(publicB64: string, privateB64: string): Promise<CryptoKeyPair> {
  const alg = { name: 'ECDH', namedCurve: 'P-256' }
  return {
    privateKey: await crypto.subtle.importKey('jwk', jwk(publicB64, privateB64), alg, true, ['deriveBits']),
    publicKey: await crypto.subtle.importKey('raw', b64uDecode(publicB64), alg, true, []),
  }
}

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, len: number) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, len * 8))
}

/** What the browser does: decrypt an aes128gcm push body with the subscription's private key. */
async function decrypt(body: Uint8Array, uaPublicB64: string, uaPrivateB64: string, authB64: string): Promise<string> {
  const salt = body.slice(0, 16)
  const idlen = body[20]
  const asPublic = body.slice(21, 21 + idlen)
  const ua = await ecdhPair(uaPublicB64, uaPrivateB64)
  const asKey = await crypto.subtle.importKey('raw', asPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const secret = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: asKey }, ua.privateKey, 256))
  const uaPublic = b64uDecode(uaPublicB64)
  const info = new Uint8Array([...te.encode('WebPush: info\0'), ...uaPublic, ...asPublic])
  const ikm = await hkdf(b64uDecode(authB64), secret, info, 32)
  const cek = await hkdf(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(salt, ikm, te.encode('Content-Encoding: nonce\0'), 12)
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt'])
  const padded = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, key, body.slice(21 + idlen)))
  let end = padded.length - 1
  while (padded[end] === 0) end--
  assert.equal(padded[end], 2, 'last-record delimiter')
  return td.decode(padded.slice(0, end))
}

test('encryption matches the RFC 8291 example exactly', async () => {
  const body = await encryptPayload(te.encode(RFC.plaintext), RFC.uaPublic, RFC.authSecret, {
    asKeys: await ecdhPair(RFC.asPublic, RFC.asPrivate),
    salt: b64uDecode(RFC.salt),
  })
  assert.equal(b64uEncode(body), RFC.body)
})

test('a browser can decrypt what we send (random keys and salt)', async () => {
  const msg = JSON.stringify({ title: 'Triple-T · ABC123', body: 'You were shot! 2 hearts left.', url: '#/game/x' })
  const body = await encryptPayload(te.encode(msg), RFC.uaPublic, RFC.authSecret)
  assert.equal(await decrypt(body, RFC.uaPublic, RFC.uaPrivate, RFC.authSecret), msg)
})

test('VAPID header is a valid ES256 JWT for the push service', async () => {
  const vapid = await generateVapid('https://triple-t.example')
  assert.equal(b64uDecode(vapid.public_key).length, 65)
  const header = await vapidAuthorization('https://fcm.googleapis.com/fcm/send/abc', vapid, 1_700_000_000_000)
  const m = header.match(/^vapid t=([^.]+)\.([^.]+)\.([^,]+), k=(.+)$/)
  assert.ok(m, header)
  const [, h, c, sig, k] = m!
  assert.equal(k, vapid.public_key)
  assert.deepEqual(JSON.parse(td.decode(b64uDecode(h))), { typ: 'JWT', alg: 'ES256' })
  assert.deepEqual(JSON.parse(td.decode(b64uDecode(c))), {
    aud: 'https://fcm.googleapis.com', exp: 1_700_000_000 + 12 * 3600, sub: 'https://triple-t.example',
  })
  const pub = await crypto.subtle.importKey('raw', b64uDecode(k), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify'])
  assert.ok(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub, b64uDecode(sig), te.encode(`${h}.${c}`)))
})

// ---------------------------------------------------------------- handler

function mockFetch(routes: Record<string, (body: unknown, init: RequestInit) => [number, unknown]>) {
  const calls: { url: string; init: RequestInit }[] = []
  const fn = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = String(input)
    calls.push({ url, init })
    const key = Object.keys(routes).find((r) => url.endsWith(r) || url.startsWith(r))
    if (!key) throw new Error(`unexpected fetch ${url}`)
    const body = typeof init.body === 'string' ? JSON.parse(init.body) : init.body
    const [status, data] = routes[key](body, init)
    return new Response(data == null ? null : JSON.stringify(data), { status })
  }) as typeof fetch
  return { fn, calls }
}

const ENV = { url: 'https://proj.supabase.co', serviceKey: 'sb_secret_test' }
const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request('https://proj.supabase.co/functions/v1/send-push', { method: 'POST', body: JSON.stringify(body), headers })

test('init creates VAPID keys once, using the site as the contact', async () => {
  let saved: Record<string, unknown> | null = null
  const { fn, calls } = mockFetch({
    '/rpc/push_public_key': () => [200, null],
    '/rpc/push_init_keys': (b) => { saved = b as Record<string, unknown>; return [200, (b as { p_public_key: string }).p_public_key] },
  })
  const res = await handle(post({ init: true }, { origin: 'https://triple-t.vercel.app' }), ENV, fn)
  const { publicKey } = await res.json()
  assert.equal(res.status, 200)
  assert.equal(publicKey, saved!.p_public_key)
  assert.equal(saved!.p_subject, 'https://triple-t.vercel.app')
  assert.equal((calls[0].init.headers as Record<string, string>).apikey, 'sb_secret_test')
  assert.equal((calls[0].init.headers as Record<string, string>).Authorization, undefined, 'sb_secret keys only go in apikey')

  const again = mockFetch({ '/rpc/push_public_key': () => [200, 'EXISTING'] })
  assert.deepEqual(await (await handle(post({ init: true }), ENV, again.fn)).json(), { publicKey: 'EXISTING' })
  assert.equal(again.calls.length, 1)
})

test('webhook sends to every subscription and drops dead ones', async () => {
  const vapid: Vapid = await generateVapid('https://triple-t.example')
  const subs = ['https://push.example/ok', 'https://push.example/gone', 'https://push.example/err'].map((endpoint) => (
    { endpoint, p256dh: RFC.uaPublic, auth: RFC.authSecret }
  ))
  let removed: unknown = null
  const pushed: { url: string; body: Uint8Array; headers: Record<string, string> }[] = []
  const { fn } = mockFetch({
    '/rpc/push_job': (b) => {
      assert.deepEqual(b, { p_event_id: 42 })
      return [200, { title: 'Triple-T · ABC123', body: 'Bob died.', url: '#/game/g1', vapid, subscriptions: subs }]
    },
    '/rpc/push_remove_subscriptions': (b) => { removed = b; return [204, null] },
  })
  // Route each push endpoint to its own status.
  const statusFor: Record<string, number> = { ok: 201, gone: 410, err: 500 }
  const routed = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input)
    if (url.startsWith('https://push.example/')) {
      pushed.push({ url, body: init!.body as Uint8Array, headers: init!.headers as Record<string, string> })
      return new Response(null, { status: statusFor[url.split('/').pop()!] })
    }
    return fn(input, init)
  }) as typeof fetch

  const res = await handle(post({ type: 'INSERT', table: 'events', record: { id: 42 } }), ENV, routed)
  assert.deepEqual(await res.json(), { sent: 1, removed: 1, failed: 1 })
  assert.deepEqual(removed, { p_endpoints: ['https://push.example/gone'] })
  assert.equal(pushed.length, 3)
  const ok = pushed.find((p) => p.url.endsWith('/ok'))!
  assert.equal(ok.headers['Content-Encoding'], 'aes128gcm')
  assert.match(ok.headers.Authorization, /^vapid t=.+, k=/)
  const msg = JSON.parse(await decrypt(ok.body, RFC.uaPublic, RFC.uaPrivate, RFC.authSecret))
  assert.deepEqual(msg, { title: 'Triple-T · ABC123', body: 'Bob died.', url: '#/game/g1' })
})

test('webhook does nothing for an event that was already sent', async () => {
  const { fn, calls } = mockFetch({ '/rpc/push_job': () => [200, null] })
  assert.deepEqual(await (await handle(post({ record: { id: 7 } }), ENV, fn)).json(), { sent: 0 })
  assert.equal(calls.length, 1)
})

test('rejects bad requests', async () => {
  const { fn } = mockFetch({})
  assert.equal((await handle(post({ hello: 1 }), ENV, fn)).status, 400)
  assert.equal((await handle(new Request('https://x/', { method: 'GET' }), ENV, fn)).status, 405)
  assert.equal((await handle(new Request('https://x/', { method: 'OPTIONS' }), ENV, fn)).status, 200)
})
