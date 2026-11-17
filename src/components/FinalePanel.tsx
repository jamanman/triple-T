import { useEffect, useState } from 'react'
import type { Game, JuryRunoff, JuryVote, Player } from '../lib/types'
import type { Act } from './GameScreen'
import Token from './Token'

interface Props {
  game: Game; players: Player[]; me: Player; myVotes: JuryVote[]; runoff?: JuryRunoff; act: Act; busy: boolean; now: number
}

export default function FinalePanel({ game, players, me, myVotes, runoff, act, busy }: Props) {
  const survivors = players.filter((p) => p.alive)
  const round = runoff?.round ?? 0
  const myVote = myVotes.find((v) => v.kind === 'winner' && v.round === round)?.target_id
  const tiedNames = runoff ? players.filter((p) => runoff.candidates.includes(p.id)).map((p) => p.name) : []
  const [plea, setPlea] = useState(me.plea ?? '')
  const [saved, setSaved] = useState(false)
  useEffect(() => setPlea(me.plea ?? ''), [me.plea])

  if (game.status === 'finished') {
    const winners = players.filter((p) => game.winner_ids?.includes(p.id))
    return (
      <div className="card finale done">
        <h2>🏆 {winners.length > 1 ? 'Shared victory' : 'Winner'}</h2>
        <div className="winners">
          {winners.map((w) => <span key={w.id} className="winner"><Token player={w} size={40} /> {w.name}</span>)}
        </div>
        <Pleas survivors={survivors} />
      </div>
    )
  }

  return (
    <div className="card finale">
      <h2>⚖️ The jury decides</h2>
      {runoff && (
        <p className="revote-banner small">
          <b>Tie!</b> Revote {round > 1 ? `#${round} ` : ''}between {tiedNames.join(' and ')}. If it ties the same way again, they share the win.
        </p>
      )}
      {me.alive ? (
        <>
          <p className="small">You survived. Tell the jury why you should win.</p>
          <textarea value={plea} maxLength={2000} rows={5} onChange={(e) => { setPlea(e.target.value); setSaved(false) }}
            placeholder="Members of the jury…" />
          <button className="primary" disabled={busy || plea === (me.plea ?? '')}
            onClick={async () => { if (await act('submit_plea', { p_plea: plea })) setSaved(true) }}>
            {saved ? 'Saved' : 'Save my plea'}
          </button>
        </>
      ) : (
        <p className="small">Read the pleas, then vote for a winner. You can change your vote until everyone has voted or time runs out.</p>
      )}
      <Pleas survivors={survivors} vote={me.alive ? undefined : {
        current: myVote, busy, allowed: runoff?.candidates, cast: (id) => act('cast_vote', { p_kind: 'winner', p_target: id }),
      }} />
    </div>
  )
}

function Pleas({ survivors, vote }: {
  survivors: Player[]
  vote?: { current?: string; busy: boolean; allowed?: string[]; cast: (id: string) => void }
}) {
  return (
    <ul className="pleas">
      {survivors.map((p) => (
        <li key={p.id} className={vote?.current === p.id ? 'voted' : ''}>
          <div className="me-row"><Token player={p} size={28} /><strong>{p.name}</strong></div>
          <blockquote>{p.plea || <span className="muted">No plea yet.</span>}</blockquote>
          {vote && (!vote.allowed || vote.allowed.includes(p.id)) && (
            <button disabled={vote.busy || vote.current === p.id} onClick={() => vote.cast(p.id)}>
              {vote.current === p.id ? '✓ Your vote' : `Vote ${p.name}`}
            </button>
          )}
        </li>
      ))}
    </ul>
  )
}
