export type GameStatus = 'lobby' | 'active' | 'finale' | 'finished'

export interface Game {
  id: string
  code: string
  host_id: string
  max_players: number
  timezone: string
  board_size: number
  max_hearts: number
  ap_drops_per_day: number
  /** 'HH:MM:SS' local time in `timezone` */
  ap_window_start: string
  ap_window_end: string
  /** null = no day limit */
  total_days: number | null
  status: GameStatus
  current_day: number
  day_ends_at: string | null
  finale_ends_at: string | null
  winner_ids: string[] | null
  created_at: string
  updated_at: string
}

export interface Player {
  id: string
  game_id: string
  user_id: string
  name: string
  color: number
  x: number | null
  y: number | null
  /** Hidden (null) for other players until the game is finished. */
  hearts: number | null
  ap: number | null
  range: number | null
  alive: boolean
  plea: string | null
}

export interface GameEvent {
  id: number
  created_at: string
  kind: string
  actor_id: string | null
  target_id: string | null
  message: string
  visible_to: string[] | null
}

export interface JuryResult {
  day: number
  haunted_id: string | null
  bonus_id: string | null
}

export interface JuryVote {
  day: number
  kind: 'haunt' | 'bonus' | 'winner'
  round: number
  target_id: string
}

/** An open revote between tied players. Daily ones are only visible to the jury. */
export interface JuryRunoff {
  day: number
  kind: 'haunt' | 'bonus' | 'winner'
  round: number
  candidates: string[]
  closes_at: string
}
