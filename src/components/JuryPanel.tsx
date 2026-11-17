import type { Game, JuryVote, Player } from '../lib/types'
import type { Act } from './GameScreen'

interface Props {
  game: Game
  players: Player[]
  me: Player
  myVotes: JuryVote[]
  act: Act
  busy: boolean
}

export default function JuryPanel({ game, players, myVotes, act, busy }: Props) {
  const living = players.filter((p) => p.alive).sort((a, b) => a.name.localeCompare(b.name))
  const vote = (kind: 'haunt' | 'bonus') =>
    myVotes.find((v) => v.kind === kind && v.day === game.current_day && v.round === 0)?.target_id ?? ''

  return (
    <div className="card jury">
      <h3>You're on the jury</h3>
      <p className="muted small">
        Your body stays on the board. Someone in range can revive you by sending a heart.
      </p>

      <p className="small">Today's votes (day {game.current_day}) are secret and close at midnight. You can change them until then. If it's a tie, one of the tied players is picked at random.</p>

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
