import { useEffect, useState } from 'react'
import { disablePush, enablePush, getPushState, type PushState } from '../lib/push'

/** Turn push notifications on or off for this device. */
export default function NotificationToggle({ compact = false }: { compact?: boolean }) {
  const [state, setState] = useState<PushState | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => { getPushState().then(setState).catch(() => setState('unsupported')) }, [])

  async function run(fn: () => Promise<PushState>) {
    setBusy(true); setError(null)
    try { setState(await fn()) } catch (e) { setError((e as Error).message) } finally { setBusy(false) }
  }

  if (state === null) return null

  return (
    <div className={`card notify${compact ? ' small' : ''}`}>
      <h3>🔔 Notifications</h3>
      {state === 'on' && (
        <div className="row">
          <span>On for this device. You'll get a notification for everything in your activity feed.</span>
          <button className="link" disabled={busy} onClick={() => run(disablePush)}>Turn off</button>
        </div>
      )}
      {state === 'off' && (
        <>
          <p className="muted small">Get notified on this device when AP drops, someone moves, you're attacked, and more, even when Triple-T is closed.</p>
          <div className="row">
            <button className="primary" disabled={busy} onClick={() => run(enablePush)}>Turn on notifications</button>
          </div>
        </>
      )}
      {state === 'needs-install' && (
        <p className="muted small">
          On iPhone and iPad, notifications only work from the Home Screen: tap <b>Share</b> → <b>Add to Home Screen</b>,
          then open Triple-T from the new icon and turn notifications on there.
        </p>
      )}
      {state === 'denied' && (
        <p className="muted small">Notifications are blocked for this site. Allow them in your browser's site settings, then reload.</p>
      )}
      {state === 'unsupported' && <p className="muted small">This browser doesn't support notifications.</p>}
      {error && <p className="error small">{error}</p>}
    </div>
  )
}
