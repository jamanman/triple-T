import { useEffect, useMemo, useState } from 'react'
import { rpc } from '../lib/supabase'
import { useGame, useNow } from '../lib/useGame'
import { countdown } from '../lib/util'
import { goTo, signOut } from '../App'
import Lobby from './Lobby'
import Board, { type Cell } from './Board'
import ActionPanel from './ActionPanel'
import PlayerList from './PlayerList'
import EventLog from './EventLog'
import JuryPanel from './JuryPanel'
import FinalePanel from './FinalePanel'

export type Act = (fn: string, args: Record<string, unknown>) => Promise<boolean>

export default function GameScreen({ gameId, userId }: { gameId: string; userId: string }) {
  const state = useGame(gameId)
  const { game, players, loading, missing, reload } = state
  const now = useNow(30_000)
  const [selected, setSelected] = useState<Cell | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const me = useMemo(() => players.find((p) => p.user_id === userId) ?? null, [players, userId])

  useEffect(() => {
    if (!error) return
    const t = window.setTimeout(() => setError(null), 5000)
    return () => window.clearTimeout(t)
  }, [error])

  const act: Act = async (fn, args) => {
    setBusy(true); setError(null)
    try {
      await rpc(fn, { p_game: gameId, ...args })
      reload()
      return true
    } catch (e) {
      setError((e as Error).message)
      return false
    } finally {
      setBusy(false)
    }
  }

  if (loading) return <main className="center-page"><p className="muted">Loading game…</p></main>
  if (missing || !game || !me) {
    return (
      <main className="center-page">
        <div className="card">
          <h2>Game not found</h2>
          <p className="muted">It may have been closed by the host, or you're not in it. (Check you're signed in with the same email you joined with.)</p>
          <button onClick={() => goTo('/')}>Home</button>
        </div>
      </main>
    )
  }

  const alive = players.filter((p) => p.alive).length
  const toast = error && <div className="toast" role="alert" onClick={() => setError(null)}>{error}</div>

  if (game.status === 'lobby') {
    return <>{toast}<Lobby game={game} players={players} me={me} act={act} busy={busy} /></>
  }

  return (
    <main className="game">
      {toast}
      <header className="topbar">
        <a href="#/" className="brand">Triple-T</a>
        <span className="mono pill">{game.code}</span>
        {game.status === 'active' && (
          <>
            <span className="pill">Day {game.current_day} / {game.total_days}</span>
            <span className="muted small">Jury tally in {countdown(game.day_ends_at, now)}</span>
          </>
        )}
        {game.status === 'finale' && <span className="pill gold">Final jury vote · ends in {countdown(game.finale_ends_at, now)}</span>}
        {game.status === 'finished' && <span className="pill gold">Game over</span>}
        <span className="muted small push">{alive} alive · {players.length - alive} on the jury</span>
        <button className="link small" onClick={signOut}>Sign out</button>
      </header>

      <div className="layout">
        <section className="board-col">
          <Board game={game} players={players} me={me} selected={selected} onSelect={setSelected} />
          <p className="muted small hint">
            AP drops twice a day at random between 8am and 8pm ({game.timezone}). Range counts up/down/left/right steps only.
          </p>
        </section>

        <aside className="side-col">
          {(game.status === 'finale' || game.status === 'finished') && (
            <FinalePanel game={game} players={players} me={me} myVotes={state.myVotes} act={act} busy={busy} now={now} />
          )}
          {game.status === 'active' && (
            me.alive
              ? <ActionPanel game={game} players={players} me={me} selected={selected} setSelected={setSelected} act={act} busy={busy} />
              : <JuryPanel game={game} players={players} me={me} myVotes={state.myVotes} act={act} busy={busy} />
          )}
          <PlayerList players={players} me={me} results={state.results} game={game}
            onPick={(p) => setSelected({ x: p.x!, y: p.y! })} />
          <EventLog events={state.events} now={now} />
        </aside>
      </div>
    </main>
  )
}
