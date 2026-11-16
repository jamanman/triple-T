import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from './supabase'
import type { Game, GameEvent, JuryResult, JuryVote, Player } from './types'

export interface GameState {
  game: Game | null
  players: Player[]
  events: GameEvent[]
  results: JuryResult[]
  myVotes: JuryVote[]
  loading: boolean
  missing: boolean
}

const EMPTY: GameState = { game: null, players: [], events: [], results: [], myVotes: [], loading: true, missing: false }

/**
 * Loads everything for one game and keeps it live: any realtime change to the
 * game's rows triggers a (debounced) reload. The data is small, so reloading
 * is simpler and more robust than patching state from change payloads.
 */
export function useGame(gameId: string) {
  const [state, setState] = useState<GameState>(EMPTY)
  const timer = useRef<number | undefined>(undefined)

  const load = useCallback(async () => {
    const [g, p, e, r, v] = await Promise.all([
      supabase.from('games').select('*').eq('id', gameId).maybeSingle(),
      supabase.from('players').select('*').eq('game_id', gameId).order('joined_at'),
      supabase.from('events').select('*').eq('game_id', gameId).order('id', { ascending: false }).limit(150),
      supabase.from('jury_results').select('*').eq('game_id', gameId).order('day'),
      supabase.from('jury_votes').select('day, kind, target_id').eq('game_id', gameId),
    ])
    setState({
      game: (g.data as Game | null) ?? null,
      players: (p.data as Player[]) ?? [],
      events: (e.data as GameEvent[]) ?? [],
      results: (r.data as JuryResult[]) ?? [],
      myVotes: (v.data as JuryVote[]) ?? [],
      loading: false,
      missing: !g.error && !g.data,
    })
  }, [gameId])

  const reload = useCallback(() => {
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(load, 120)
  }, [load])

  useEffect(() => {
    setState(EMPTY)
    load()
    const filter = `game_id=eq.${gameId}`
    const channel = supabase
      .channel(`game-${gameId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'games', filter: `id=eq.${gameId}` }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'players', filter }, reload)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'events', filter }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'jury_results', filter }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'jury_votes', filter }, reload)
      .subscribe((status) => { if (status === 'SUBSCRIBED') reload() })

    // Safety nets for missed realtime messages (sleeping laptops, flaky mobile).
    const onFocus = () => reload()
    window.addEventListener('focus', onFocus)
    const poll = window.setInterval(reload, 60_000)
    return () => {
      supabase.removeChannel(channel)
      window.removeEventListener('focus', onFocus)
      window.clearInterval(poll)
      window.clearTimeout(timer.current)
    }
  }, [gameId, load, reload])

  return { ...state, reload }
}

/** A clock that re-renders every `ms` milliseconds. */
export function useNow(ms = 30_000) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), ms)
    return () => window.clearInterval(t)
  }, [ms])
  return now
}
