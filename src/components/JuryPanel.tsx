import type { Game, JuryRunoff, JuryVote, Player } from '../lib/types'
import { countdown } from '../lib/util'
import type { Act } from './GameScreen'

interface Props {
  game: Game
  players: Player[]
  me: Player
  myVotes: JuryVote[]
  runoffs: JuryRunoff[]
  act: Act
  busy: boolean
  now: number
}

const LABEL = { haunt: '👻 Haunt', bonus: '⭐ +2 AP' } as const

export default function JuryPanel({ game, players, myVotes, runoffs, act, busy, now }: Props) {
  const living = players.filter((p) => p.alive).sort((a, b) => a.name.localeCompare(b.name))
  const vote = (kind: 'haunt' | 'bonus') =>
    myVotes.find((v) => v.kind === kind && v.day === game.current_day && v.round === 0)?.target_id ?? ''
  const revotes = runoffs.filter((r): r is JuryRunoff & { kind: 'haunt' | 'bonus' } => r.kind !== 'winner')

  return (
    <div className="card jury">
      <h3>You're on the jury</h3>
      <p className="muted small">
        Your body stays on the board. Someone in range can revive you by sending a heart.
      </p>

      {revotes.map((r) => {
        const mine = myVotes.find((v) => v.kind === r.kind && v.day === r.day && v.round === r.round)?.target_id
        return (
          <div key={r.kind} className="revote">
            <p className="small">
              <b>Tie on day {r.day}'s {r.kind === 'haunt' ? 'haunt' : 'bonus'} vote.</b> Revote between only the tied players.
              Closes in {countdown(r.closes_at, now)}; if it's still tied, nobody gets it.
            </p>
            <div className="row">
              {players.filter((p) => r.candidates.includes(p.id)).map((p) => (
                <button key={p.id} disabled={busy || mine === p.id}
                  onClick={() => act('cast_revote', { p_kind: r.kind, p_target: p.id })}>
                  {mine === p.id ? `✓ ${p.name}` : `${LABEL[r.kind]}: ${p.name}`}
                </button>
              ))}
            </div>
          </div>
        )
      })}

      <p className="small">Today's votes (day {game.current_day}) are secret and close at midnight. You can change them until then. A tie goes to a revote.</p>

      <label className="field">
        <span>👻 Haunt: no AP for them tomorrow</span>
        <select value={vote('haunt')} disabled={busy}
          onChange={(e) => e.target.value && act('cast_vote', { p_kind: 'haunt', p_target: e.target.value })}>
          <option value="">Choose a player…</option>
          {living.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
      </label>

      <label className="field">
        <span>⭐ Reward: +2 AP</span>
        <select value={vote('bonus')} disabled={busy}
          onChange={(e) => e.target.value && act('cast_vote', { p_kind: 'bonus', p_target: e.target.value })}>
          <option value="">Choose a player…</option>
          {living.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
      </label>
    </div>
  )
}
