import type { GameEvent } from '../lib/types'
import { timeAgo } from '../lib/util'

const ICON: Record<string, string> = {
  move: '→', shoot: '💥', kill: '☠️', heal: '♥', upgrade: '⌖', gift_ap: '🎁', gift_heart: '🎁',
  revive: '✨', loot: '💰', join: '👋', leave: '🚪', plea: '📜', ap_drop: '⚡', new_day: '🌅', haunt: '👻', bonus: '⭐', finale: '⚖️', winner: '🏆', start: '🚩',
}

export default function EventLog({ events, now }: { events: GameEvent[]; now: number }) {
  return (
    <div className="card">
      <h3>Activity</h3>
      <ol className="log">
        {events.map((e) => (
          <li key={e.id} className={`log-${e.kind}`}>
            <span className="icon">{ICON[e.kind] ?? '•'}</span>
            <span className="msg">{e.message}{e.visible_to && <span className="private" title="Only you (and the other player involved) can see this"> 🔒</span>}</span>
            <time className="muted small" title={new Date(e.created_at).toLocaleString()}>{timeAgo(e.created_at, now)}</time>
          </li>
        ))}
        {events.length === 0 && <li className="muted small">Nothing has happened yet.</li>}
      </ol>
    </div>
  )
}
