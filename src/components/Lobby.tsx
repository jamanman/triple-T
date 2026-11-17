import { useEffect, useState } from 'react'
import type { Game, Player } from '../lib/types'
import { allTimeZones, clock, dropSchedule } from '../lib/util'
import { goTo } from '../App'
import type { Act } from './GameScreen'
import Token from './Token'

interface Props { game: Game; players: Player[]; me: Player; act: Act; busy: boolean }

export default function Lobby({ game, players, me, act, busy }: Props) {
  const isHost = game.host_id === me.user_id
  const [copied, setCopied] = useState(false)
  const [unsaved, setUnsaved] = useState(false)
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

      {isHost
        ? <SettingsForm game={game} playerCount={players.length} act={act} busy={busy} onDirty={setUnsaved} />
        : <SettingsSummary game={game} />}

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
        <div className="row">
          {isHost && (
            <button className="primary" disabled={busy || players.length < 4} onClick={() => (!unsaved || confirm('Your settings changes are not saved. Start with the saved settings?')) && act('start_game', {})}>
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

function SettingsSummary({ game }: { game: Game }) {
  return (
    <div className="card">
      <h2>Game settings</h2>
      <dl className="settings-list">
        <dt>Length</dt><dd>{game.total_days == null ? 'No limit (ends when 3 players remain)' : `${game.total_days} days`}</dd>
        <dt>Grid</dt><dd>{game.board_size}×{game.board_size}</dd>
        <dt>Max players</dt><dd>{game.max_players}</dd>
        <dt>Max hearts</dt><dd>{game.max_hearts} (everyone starts with {Math.min(3, game.max_hearts)})</dd>
        <dt>AP drops</dt><dd>{dropSchedule(game)}</dd>
      </dl>
      <p className="muted small">The host can change these until the game starts.</p>
    </div>
  )
}

const hhmm = (t: string) => t.slice(0, 5)

function SettingsForm({ game, playerCount, act, busy, onDirty }: {
  game: Game; playerCount: number; act: Act; busy: boolean; onDirty: (dirty: boolean) => void
}) {
  const fromGame = () => ({
    board: game.board_size,
    players: game.max_players,
    hearts: game.max_hearts,
    drops: game.ap_drops_per_day,
    start: hhmm(game.ap_window_start),
    end: hhmm(game.ap_window_end),
    tz: game.timezone,
    days: game.total_days, // null = no limit
  })
  const [s, setS] = useState(fromGame)
  const [saved, setSaved] = useState(false)
  // Pick up saved values (e.g. after a save or a reload).
  useEffect(() => setS(fromGame()), [game.updated_at]) // eslint-disable-line react-hooks/exhaustive-deps

  const set = <K extends keyof typeof s>(k: K, v: (typeof s)[K]) => { setS({ ...s, [k]: v }); setSaved(false) }
  const dirty = JSON.stringify(s) !== JSON.stringify(fromGame())
  const windowOk = s.start < s.end
  useEffect(() => onDirty(dirty), [dirty, onDirty])

  async function save() {
    const ok = await act('update_settings', {
      p_board_size: s.board, p_max_players: s.players, p_max_hearts: s.hearts, p_ap_drops_per_day: s.drops,
      p_ap_window_start: s.start, p_ap_window_end: s.end, p_timezone: s.tz, p_total_days: s.days,
    })
    if (ok) setSaved(true)
  }

  return (
    <div className="card">
      <h2>Game settings</h2>
      <div className="settings-grid">
        <div className="field">
          <span>Game length</span>
          <div className="time-row">
            <input type="number" min={1} max={365} disabled={s.days == null} aria-label="Number of days"
              value={s.days ?? ''} onChange={(e) => set('days', Math.min(365, Math.max(1, Math.floor(+e.target.value || 1))))} />
            <span>days</span>
            <label className="check">
              <input type="checkbox" checked={s.days == null} onChange={(e) => set('days', e.target.checked ? null : 5)} />
              No limit
            </label>
          </div>
          {s.days == null && <small className="muted">The game ends only when 3 players remain.</small>}
        </div>
        <label className="field">
          <span>Grid size: <strong>{s.board}×{s.board}</strong></span>
          <input type="range" min={10} max={20} value={s.board} onChange={(e) => set('board', +e.target.value)} />
        </label>
        <label className="field">
          <span>Max players: <strong>{s.players}</strong></span>
          <input type="range" min={Math.max(4, playerCount)} max={25} value={s.players} onChange={(e) => set('players', +e.target.value)} />
        </label>
        <label className="field">
          <span>Max hearts: <strong>{s.hearts}</strong> <small>(start with {Math.min(3, s.hearts)})</small></span>
          <input type="range" min={1} max={10} value={s.hearts} onChange={(e) => set('hearts', +e.target.value)} />
        </label>
        <label className="field">
          <span>AP drops per day: <strong>{s.drops}</strong></span>
          <input type="range" min={1} max={12} value={s.drops} onChange={(e) => set('drops', +e.target.value)} />
        </label>
        <div className="field">
          <span>AP can drop between</span>
          <div className="time-row">
            <input type="time" value={s.start} onChange={(e) => set('start', e.target.value)} aria-label="Window start" />
            <span>and</span>
            <input type="time" value={s.end} onChange={(e) => set('end', e.target.value)} aria-label="Window end" />
          </div>
          {!windowOk && <small className="error">The start time must be before the end time.</small>}
        </div>
        <label className="field">
          <span>Time zone</span>
          <select value={s.tz} onChange={(e) => set('tz', e.target.value)}>
            {allTimeZones(s.tz).map((z) => <option key={z}>{z}</option>)}
          </select>
        </label>
      </div>
      <p className="muted small">
        {s.drops === 1 ? 'One drop' : `${s.drops} drops`} a day, each at a random time between {clock(s.start)} and {clock(s.end)}.
      </p>
      <div className="row">
        <button className="primary" disabled={busy || !dirty || !windowOk} onClick={save}>
          {saved && !dirty ? 'Saved' : 'Save settings'}
        </button>
        {dirty && <span className="muted small">Unsaved changes. Players see the saved settings.</span>}
      </div>
    </div>
  )
}
