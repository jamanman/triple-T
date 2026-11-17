import { useMemo } from 'react'
import type { Game, Player } from '../lib/types'
import { dist } from '../lib/util'
import Token from './Token'

export interface Cell { x: number; y: number }

interface Props {
  game: Game
  players: Player[]
  me: Player
  selected: Cell | null
  onSelect: (c: Cell | null) => void
}

export default function Board({ game, players, me, selected, onSelect }: Props) {
  const size = game.board_size
  const byCell = useMemo(() => {
    const m = new Map<string, Player>()
    for (const p of players) if (p.x != null && p.y != null) m.set(`${p.x},${p.y}`, p)
    return m
  }, [players])

  const canAct = game.status === 'active' && me.alive
  const cells = []
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const p = byCell.get(`${x},${y}`)
      const d = dist({ x, y }, me)
      const inRange = canAct && d <= (me.range ?? 0) && d > 0
      const canMoveHere = canAct && !p && d === 1
      const isSel = selected?.x === x && selected?.y === y
      const cls = ['cell', inRange && 'in-range', canMoveHere && 'move-target', isSel && 'selected', p?.id === me.id && 'mine']
        .filter(Boolean).join(' ')
      cells.push(
        <button
          key={`${x},${y}`}
          className={cls}
          onClick={() => onSelect(isSel ? null : { x, y })}
          aria-label={p ? `${p.name}${p.alive ? '' : ' (dead)'} at ${x + 1},${y + 1}` : `Empty square ${x + 1},${y + 1}`}
        >
          {p && <Token player={p} />}
          {p && p.alive && p.hearts != null && <span className="hearts-badge">{p.hearts}</span>}
        </button>,
      )
    }
  }

  return (
    <div className="board" style={{ gridTemplateColumns: `repeat(${size}, 1fr)` }}>
      {cells}
    </div>
  )
}
