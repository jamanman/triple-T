import type { Player } from '../lib/types'
import { colorOf, initials, textOn } from '../lib/util'

/** A player's coloured disc with initials. Dead players are hollow and crossed out. */
export default function Token({ player, size }: { player: Player; size?: number }) {
  const c = colorOf(player)
  const style = size ? { width: size, height: size, fontSize: size * 0.4 } : undefined
  return (
    <span
      className={`token${player.alive ? '' : ' dead'}`}
      style={{ ...style, background: player.alive ? c : 'transparent', color: player.alive ? textOn(c) : c, borderColor: c }}
      title={`${player.name}${player.alive ? '' : ' (dead)'}`}
    >
      {initials(player.name)}
    </span>
  )
}
