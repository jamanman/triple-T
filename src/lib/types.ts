export type GameStatus = 'lobby' | 'active' | 'finale' | 'finished'

export interface Game {
  id: string
  code: string
  host_id: string
  max_players: number
  timezone: string
  board_size: number
  total_days: number
  status: GameStatus
  current_day: number
  day_ends_at: string | null
  finale_ends_at: string | null
  winner_ids: string[] | null
  created_at: string
}

export interface Player {
  id: string
  game_id: string
  user_id: string
  name: string
  color: number
  x: number | null
  y: number | null
  hearts: number
  ap: number
  range: number
  alive: boolean
  killed_by: string | null
  plea: string | null
}

export interface GameEvent {
  id: number
  created_at: string
  kind: string
  actor_id: string | null
  target_id: string | null
  message: string
}

export interface JuryResult {
  day: number
  haunted_id: string | null
  bonus_id: string | null
}

export interface JuryVote {
  day: number
  kind: 'haunt' | 'bonus' | 'winner'
  target_id: string
}
