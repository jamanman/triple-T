import { useEffect, useState, type FormEvent } from 'react'
import { rpc, supabase } from '../lib/supabase'
import type { Game } from '../lib/types'
import { goTo } from '../App'

const NAME_KEY = 'triple-t:name'

function loadName() {
  try { return localStorage.getItem(NAME_KEY) ?? '' } catch { return '' }
}

const STATUS_LABEL: Record<Game['status'], string> = {
  lobby: 'In lobby', active: 'In progress', finale: 'Jury deciding', finished: 'Finished',
}

export default function Home({ initialCode }: { initialCode?: string }) {
  const [name, setName] = useState(loadName)
  const [maxPlayers, setMaxPlayers] = useState(10)
  const [timezone, setTimezone] = useState(Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC')
  const [code, setCode] = useState(initialCode ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [games, setGames] = useState<Game[]>([])

  useEffect(() => {
    // RLS only returns games you're in.
    supabase.from('games').select('*').order('created_at', { ascending: false }).limit(20)
      .then(({ data }) => setGames((data as Game[]) ?? []))
  }, [])

  const zones = (() => {
    try { return (Intl as unknown as { supportedValuesOf(k: string): string[] }).supportedValuesOf('timeZone') }
    catch { return [timezone] }
  })()

  async function run(fn: () => Promise<string>) {
    if (!name.trim()) return setError('Pick a name first')
    try { localStorage.setItem(NAME_KEY, name.trim()) } catch { /* private mode */ }
    setBusy(true); setError(null)
    try { goTo(`/game/${await fn()}`) } catch (e) { setError((e as Error).message) } finally { setBusy(false) }
  }

  const create = (e: FormEvent) => {
    e.preventDefault()
    run(() => rpc<string>('create_game', { p_name: name, p_max_players: maxPlayers, p_timezone: timezone }))
  }
  const join = (e: FormEvent) => {
    e.preventDefault()
    if (!code.trim()) return setError('Enter a game code')
    run(() => rpc<string>('join_game', { p_code: code, p_name: name }))
  }

  return (
    <main className="home">
      <header className="hero">
        <h1>Triple-T</h1>
        <p className="muted">A slow-burn battle on a 15×15 grid. Five days. Two AP drops a day. The dead decide who wins.</p>
      </header>

      <div className="card">
        <label className="field">
          <span>Your name</span>
          <input value={name} maxLength={20} onChange={(e) => setName(e.target.value)} placeholder="e.g. Sam" />
        </label>
      </div>

      <div className="home-grid">
        <form className="card" onSubmit={create}>
          <h2>Create a lobby</h2>
          <label className="field">
            <span>Max players: <strong>{maxPlayers}</strong></span>
            <input type="range" min={4} max={20} value={maxPlayers} onChange={(e) => setMaxPlayers(+e.target.value)} />
          </label>
          <label className="field">
            <span>Time zone for AP drops (8am–8pm)</span>
            <select value={timezone} onChange={(e) => setTimezone(e.target.value)}>
              {zones.map((z) => <option key={z}>{z}</option>)}
            </select>
          </label>
          <button className="primary" disabled={busy}>Create lobby</button>
        </form>

        <form className="card" onSubmit={join}>
          <h2>Join a lobby</h2>
          <label className="field">
            <span>Game code</span>
            <input value={code} maxLength={6} onChange={(e) => setCode(e.target.value.toUpperCase())}
              placeholder="ABC123" className="code-input" />
          </label>
          <button className="primary" disabled={busy}>Join</button>
        </form>
      </div>

      {error && <p className="error">{error}</p>}

      {games.length > 0 && (
        <div className="card">
          <h2>Your games</h2>
          <ul className="game-list">
            {games.map((g) => (
              <li key={g.id}>
                <a href={`#/game/${g.id}`}>
                  <span className="mono">{g.code}</span>
                  <span className="muted">{STATUS_LABEL[g.status]}{g.status === 'active' ? ` · day ${g.current_day}/${g.total_days}` : ''}</span>
                </a>
              </li>
            ))}
          </ul>
        </div>
      )}

      <details className="card rules">
        <summary>Rules</summary>
        <ul>
          <li>Everyone starts on a random square with 3 hearts, 0 AP and a range of 2.</li>
          <li>Twice a day, at random times between 8am and 8pm, every living player gets 1 AP.</li>
          <li>At any time, spend AP to: <b>move</b> one square up/down/left/right (1 AP), <b>shoot</b> someone in range (1 AP, −1 heart), <b>add a heart</b> (3 AP, max 4), or <b>upgrade range</b> by 1 (3 AP).</li>
          <li>Range counts diagonals, so range 2 is the 5×5 square around you.</li>
          <li>Send hearts or AP as gifts to anyone in range. A heart sent to a dead player revives them with 1 heart and 0 AP.</li>
          <li>At 0 hearts you're dead: your AP goes to your killer and your body stays on the board.</li>
          <li>The dead form the jury. Each day they vote to <b>haunt</b> one player (no AP the next day) and to give one player <b>+2 AP</b>.</li>
          <li>When 3 players remain, or after day 5, survivors plead their case and the jury votes for the winner.</li>
        </ul>
      </details>
    </main>
  )
}
