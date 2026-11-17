import { useEffect, useState, type FormEvent } from 'react'
import { rpc, supabase } from '../lib/supabase'
import type { Game } from '../lib/types'
import { browserTimeZone, dayLabel } from '../lib/util'
import { goTo, signOut } from '../App'

const STATUS_LABEL: Record<Game['status'], string> = {
  lobby: 'In lobby', active: 'In progress', finale: 'Jury deciding', finished: 'Finished',
}

interface Props { initialCode?: string; email: string; displayName: string }

export default function Home({ initialCode, email, displayName }: Props) {
  const [name, setName] = useState(displayName)
  const [code, setCode] = useState(initialCode ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [games, setGames] = useState<Game[]>([])

  useEffect(() => {
    // RLS only returns games you're in.
    supabase.from('games').select('*').order('created_at', { ascending: false }).limit(20)
      .then(({ data }) => setGames((data as Game[]) ?? []))
  }, [])

  async function run(fn: () => Promise<string>) {
    if (!name.trim()) return setError('Pick a name first')
    setBusy(true); setError(null)
    try { goTo(`/game/${await fn()}`) } catch (e) { setError((e as Error).message) } finally { setBusy(false) }
  }

  const create = (e: FormEvent) => {
    e.preventDefault()
    run(() => rpc<string>('create_game', { p_name: name, p_max_players: 10, p_timezone: browserTimeZone() }))
  }
  const join = (e: FormEvent) => {
    e.preventDefault()
    if (!code.trim()) return setError('Enter a game code')
    run(() => rpc<string>('join_game', { p_code: code, p_name: name }))
  }

  return (
    <main className="home">
      <div className="account small">
        <span className="muted">Signed in as {email}</span>
        <button className="link" onClick={signOut}>Sign out</button>
      </div>
      <header className="hero">
        <h1>Triple-T</h1>
        <p className="muted">A slow-burn battle on a grid. AP drops at random times. The dead decide who wins.</p>
      </header>

      <div className="card">
        <label className="field">
          <span>Your name in the game</span>
          <input value={name} maxLength={20} onChange={(e) => setName(e.target.value)} placeholder="e.g. Sam" />
        </label>
      </div>

      <div className="home-grid">
        <form className="card" onSubmit={create}>
          <h2>Create a lobby</h2>
          <p className="muted small">You'll choose the grid size, player limit, max hearts and AP schedule in the lobby before starting.</p>
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
                  <span className="muted">{STATUS_LABEL[g.status]}{g.status === 'active' ? ` · ${dayLabel(g).toLowerCase()}` : ''}</span>
                </a>
              </li>
            ))}
          </ul>
        </div>
      )}

      <details className="card rules">
        <summary>Rules</summary>
        <ul>
          <li>Everyone starts on a random square of the grid (15×15 by default) with 3 hearts, 0 AP and a range of 2. Your hearts, AP and range are secret: nobody else can see them until the game ends.</li>
          <li>Several times a day, at random times inside a window, every living player gets 1 AP. The host sets how many drops and the window (8am–8pm, twice a day, by default).</li>
          <li>At any time, spend AP to: <b>move</b> one square up/down/left/right (1 AP), <b>shoot</b> someone in range (1 AP, −1 heart), <b>add a heart</b> (3 AP, up to the game's max, 4 by default), or <b>upgrade range</b> by 1 (3 AP).</li>
          <li>Range is counted in up/down/left/right steps, never diagonally. Range 2 reaches a square 2 steps away, or one step across and one step up.</li>
          <li>Send hearts or AP as gifts to anyone in range (gifts can't take anyone above the max hearts). A heart sent to a dead player revives them with 1 heart and 0 AP.</li>
          <li>At 0 hearts you're dead: your AP goes to your killer and your body stays on the board.</li>
          <li>The activity feed shows AP drops, moves, deaths and revives. If you're shot, only you are told, and never by whom. If you're sent a gift, only you are told, and you see who sent it.</li>
          <li>The dead form the jury. Each day they vote to <b>haunt</b> one player (no AP the next day) and to give one player <b>+2 AP</b>.</li>
          <li>When 3 players remain, or after the last day (the host sets the game length, or no limit), survivors plead their case and the jury votes for the winner.</li>
          <li>If a jury vote is tied, the jury revotes between only the tied players.</li>
        </ul>
      </details>
    </main>
  )
}
