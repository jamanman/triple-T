import { rpc, supabase } from './supabase'

/**
 * unsupported   – this browser can't do Web Push
 * needs-install – iPhone/iPad: only works once the site is added to the Home Screen
 * denied        – the player blocked notifications for this site
 * off / on      – this device is (not) subscribed
 */
export type PushState = 'unsupported' | 'needs-install' | 'denied' | 'off' | 'on'

const SW_URL = `${import.meta.env.BASE_URL}sw.js`

const isIOS = () =>
  /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)

const isStandalone = () =>
  window.matchMedia('(display-mode: standalone)').matches ||
  (navigator as Navigator & { standalone?: boolean }).standalone === true

const supported = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window

/** Register the service worker on startup, and follow its "open this game" requests. */
export function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return
  navigator.serviceWorker.register(SW_URL).catch((e) => console.warn('Service worker failed to register', e))
  navigator.serviceWorker.addEventListener('message', (e) => {
    if (e.data?.type === 'navigate' && typeof e.data.url === 'string') window.location.href = e.data.url
  })
}

async function registration(): Promise<ServiceWorkerRegistration> {
  return (await navigator.serviceWorker.getRegistration(SW_URL)) ?? navigator.serviceWorker.register(SW_URL)
}

export async function getPushState(): Promise<PushState> {
  if (!supported()) return isIOS() && !isStandalone() ? 'needs-install' : 'unsupported'
  if (Notification.permission === 'denied') return 'denied'
  const sub = await (await registration()).pushManager.getSubscription()
  return sub && Notification.permission === 'granted' ? 'on' : 'off'
}

function keyBytes(b64url: string): Uint8Array<ArrayBuffer> {
  const b64 = b64url.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((b64url.length + 3) % 4)
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

async function publicKey(): Promise<string> {
  const existing = await rpc<string | null>('push_public_key', {})
  if (existing) return existing
  // First player ever to turn notifications on: the edge function creates the keys.
  const { data, error } = await supabase.functions.invoke<{ publicKey?: string }>('send-push', { body: { init: true } })
  if (error || !data?.publicKey) {
    throw new Error("Notifications aren't set up on the server yet (the send-push function). See the README.")
  }
  return data.publicKey
}

async function save(sub: PushSubscription) {
  const json = sub.toJSON()
  await rpc('save_push_subscription', {
    p_endpoint: sub.endpoint, p_p256dh: json.keys?.p256dh, p_auth: json.keys?.auth,
  })
}

/** Ask permission (must be called from a click) and subscribe this device. */
export async function enablePush(): Promise<PushState> {
  const permission = await Notification.requestPermission()
  if (permission !== 'granted') return permission === 'denied' ? 'denied' : 'off'
  const key = await publicKey()
  const reg = await registration()
  let sub = await reg.pushManager.getSubscription()
  if (!sub) {
    try {
      sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(key) })
    } catch (e) {
      console.warn(e)
      throw new Error(
        "This browser couldn't set up notifications. Check that notifications are allowed for this site. " +
        "(In Brave, turn on \"Use Google services for push messaging\" in Settings → Privacy.)",
      )
    }
  }
  await save(sub)
  return 'on'
}

export async function disablePush(): Promise<PushState> {
  const sub = await (await registration()).pushManager.getSubscription()
  if (sub) {
    await rpc('delete_push_subscription', { p_endpoint: sub.endpoint }).catch(() => {})
    await sub.unsubscribe()
  }
  return 'off'
}

/** On startup: make sure this device's subscription is filed under whoever is signed in now. */
export async function syncPush() {
  try {
    if (!supported() || Notification.permission !== 'granted') return
    const sub = await (await registration()).pushManager.getSubscription()
    if (sub) await save(sub)
  } catch (e) {
    console.warn('Could not sync push subscription', e)
  }
}

/** On sign-out: stop this device getting the old account's notifications. */
export async function forgetPushOnThisDevice() {
  try {
    if (!supported()) return
    const sub = await (await registration()).pushManager.getSubscription()
    if (sub) await rpc('delete_push_subscription', { p_endpoint: sub.endpoint })
  } catch {
    /* signing out anyway */
  }
}
