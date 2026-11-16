import { useEffect, useState } from 'react'
import type { Game, Player } from '../lib/types'
import { dist, plural } from '../lib/util'
import type { Act } from './GameScreen'
import type { Cell } from './Board'
import Token from './Token'

interface Props {
  game: Game
  players: Player[]
  me: Player
  selected: Cell | null
  setSelected: (c: Cell | null) => void
  act: Act
  busy: boolean
}

export function Hearts({ n }: { n: number }) {
  return (
    <span className="hearts" aria-label={plural(n, 'heart')}>
      {Array.from({ length: Math.max(4, n) }, (_, i) => <span key={i} className={i < n ? 'on' : 'off'}>♥</span>)}
    </span>
  )
}

export default function ActionPanel({ game, players, me: meRow, selected, setSelected, act, busy }: Props) {
  // Your own stats are always visible to you.
  const me = { ...meRow, hearts: meRow.hearts ?? 0, ap: meRow.ap ?? 0, range: meRow.range ?? 0 }
  const target = selected ? players.find((p) => p.x === selected.x && p.y === selected.y) ?? null : null
  const [amount, setAmount] = useState(1)
  useEffect(() => setAmount(1), [target?.id])

  // Arrow keys / WASD pick the neighbouring square; Enter moves there.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement).closest('input, textarea, select')) return
      const d: Record<string, [number, number]> = {
        ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0],
        w: [0, -1], s: [0, 1], a: [-1, 0], d: [1, 0],
      }
      const v = d[e.key]
      if (!v) return
      e.preventDefault()
      const x = me.x! + v[0], y = me.y! + v[1]
      if (x >= 0 && y >= 0 && x < game.board_size && y < game.board_size) setSelected({ x, y })
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [me.x, me.y, game.board_size, setSelected])

  const isAdjacent = selected && dist(selected, me) === 1
  const d = target ? dist(me, target) : 0
  const inRange = target && d <= me.range

  return (
    <div className="card">
      <div className="me-row">
        <Token player={me} size={36} />
        <div>
          <strong>{me.name}</strong>
          <div className="stats">
            <Hearts n={me.hearts} />
            <span className="stat"><b>{me.ap}</b> AP</span>
            <span className="stat">range <b>{me.range}</b></span>
          </div>
        </div>
      </div>

      <div className="row">
        <button disabled={busy || me.ap < 3 || me.hearts >= 4} onClick={() => act('act_add_heart', {})}>
          ♥ Add heart <small>3 AP</small>
        </button>
        <button disabled={busy || me.ap < 3} onClick={() => act('act_upgrade_range', {})}>
          ⌖ Range +1 <small>3 AP</small>
        </button>
      </div>

      <div className="selection">
        {!selected && <p className="muted small">Tap a square or player on the board. Arrow keys pick a square next to you. Shaded squares are in your range.</p>}

        {selected && !target && (
          isAdjacent ? (
            <button className="primary wide" disabled={busy || me.ap < 1}
              onClick={async () => { if (await act('act_move', { p_x: selected.x, p_y: selected.y })) setSelected(null) }}
              onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.click()} autoFocus>
              Move here <small>1 AP</small>
            </button>
          ) : (
            <p className="muted small">Empty square. You can only move one square up, down, left or right.</p>
          )
        )}

        {target && target.id === me.id && <p className="muted small">That's you.</p>}

        {target && target.id !== me.id && (
          <>
            <div className="me-row">
              <Token player={target} size={30} />
              <div>
                <strong>{target.name}</strong>{!target.alive && <span className="muted"> · dead</span>}
                <div className="stats small">
                  <span className="stat">{plural(d, 'step')} away</span>
                  <span className="muted">stats hidden</span>
                </div>
              </div>
            </div>

            {!inRange && <p className="muted small">Out of your range ({me.range}).</p>}

            {inRange && target.alive && (
              <>
                <button className="danger wide" disabled={busy || me.ap < 1}
                  onClick={() => act('act_shoot', { p_target: target.id })}>
                  Shoot {target.name} <small>1 AP</small>
                </button>
                <div className="gift-row">
                  <span className="small">Gift</span>
                  <input type="number" min={1} max={Math.max(1, me.ap, me.hearts - 1)} value={amount} aria-label="Gift amount"
                    onChange={(e) => setAmount(Math.max(1, Math.floor(+e.target.value || 1)))} />
                  <button disabled={busy || me.hearts - amount < 1}
                    onClick={() => act('gift', { p_target: target.id, p_kind: 'heart', p_amount: amount })}>
                    ♥ {amount === 1 ? 'heart' : 'hearts'}
                  </button>
                  <button disabled={busy || me.ap < amount}
                    onClick={() => act('gift', { p_target: target.id, p_kind: 'ap', p_amount: amount })}>
                    AP
                  </button>
                </div>
              </>
            )}

            {inRange && !target.alive && (
              <button className="primary wide" disabled={busy || me.hearts < 2}
                onClick={() => act('gift', { p_target: target.id, p_kind: 'heart', p_amount: 1 })}>
                Revive {target.name} <small>costs you 1 heart</small>
              </button>
            )}
          </>
        )}
      </div>
    </div>
  )
}
