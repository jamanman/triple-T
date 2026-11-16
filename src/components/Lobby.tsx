import { useState } from 'react'
import type { Game, Player } from '../lib/types'
import { goTo } from '../App'
import type { Act } from './GameScreen'
import Token from './Token'

interface Props { game: Game; players: Player[]; me: Player; act: Act; busy: boolean }

export default function Lobby({ game, players, me, act, busy }: Props) {
  const isHost = game.host_id === me.user_id
  const [copied, setCopied] = useState(false)
  const link = `${window.location.origin}${window.location.pathname}#/join/${game.code}`

  async function copy() {
    try { await navigator.clipboard.writeText(link); setCopied(true); setTimeout(() => setCopied(false), 1500) } catch { /* ignore */ }
  }

  async function leave() {
    if (isHost && !confirm('Leaving closes the lobby for everyone. Continue?')) return
    if (await act('leave_game', {})) goTo('/')
  }

  return (
    <main className="home">
      <div className="card lobby-head">
        <p className="muted">Game code</p>
        <p className="big-code mono">{game.code}</p>
        <button onClick={copy}>{copied ? 'Copied!' : 'Copy invite link'}</button>
      </div>

      <div className="card">
        <h2>Players {players.length} / {game.max_players}</h2>
        <ul className="lobby-players">
          {players.map((p) => (
            <li key={p.id}>
              <Token player={p} size={32} />
              <span>{p.name}</span>
              {p.user_id === game.host_id && <span className="pill small">host</span>}
              {p.id === me.id && <span className="muted small">(you)</span>}
            </li>
          ))}
        </ul>
        <p className="muted small">AP drops follow {game.timezone} time. Five days of play once the host starts.</p>
        <div className="row">
          {isHost && (
            <button className="primary" disabled={busy || players.length < 4} onClick={() => act('start_game', {})}>
              {players.length < 4 ? `Need ${4 - players.length} more to start` : 'Start game'}
            </button>
          )}
          {!isHost && <p className="muted">Waiting for the host to start…</p>}
          <button disabled={busy} onClick={leave}>{isHost ? 'Close lobby' : 'Leave'}</button>
        </div>
      </div>
    </main>
  )
}
