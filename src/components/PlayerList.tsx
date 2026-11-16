import type { Game, JuryResult, Player } from '../lib/types'
import Token from './Token'
import { Hearts } from './ActionPanel'

interface Props {
  game: Game
  players: Player[]
  me: Player
  results: JuryResult[]
  onPick: (p: Player) => void
}

export default function PlayerList({ game, players, me, results, onPick }: Props) {
  const haunted = results.find((r) => r.day === game.current_day - 1)?.haunted_id
  const sorted = [...players].sort((a, b) => Number(b.alive) - Number(a.alive) || a.name.localeCompare(b.name))
  const winners = new Set(game.winner_ids ?? [])

  return (
    <div className="card">
      <h3>Players</h3>
      <ul className="player-list">
        {sorted.map((p) => (
          <li key={p.id}>
            <button className={`player-row${p.alive ? '' : ' is-dead'}`} onClick={() => onPick(p)}>
              <Token player={p} size={24} />
              <span className="name">
                {p.name}{p.id === me.id && <span className="muted"> (you)</span>}
                {winners.has(p.id) && ' 🏆'}
                {game.status === 'active' && p.id === haunted && <span title="Haunted: no AP today"> 👻</span>}
              </span>
              {p.alive ? (
                p.hearts != null && (
                  <span className="row-stats"><Hearts n={p.hearts} /><span>{p.ap} AP</span><span>r{p.range}</span></span>
                )
              ) : (
                <span className="muted small">jury</span>
              )}
            </button>
          </li>
        ))}
      </ul>
    </div>
  )
}
