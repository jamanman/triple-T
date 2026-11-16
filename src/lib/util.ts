import type { Player } from './types'

// 20 visually distinct colours, one per player slot.
export const PLAYER_COLORS = [
  '#e6194b', '#3cb44b', '#ffe119', '#4363d8', '#f58231',
  '#911eb4', '#42d4f4', '#f032e6', '#bfef45', '#fabed4',
  '#469990', '#dcbeff', '#9a6324', '#fffac8', '#800000',
  '#aaffc3', '#808000', '#ffd8b1', '#000075', '#ffffff',
]

export function colorOf(p: Pick<Player, 'color'>): string {
  return PLAYER_COLORS[p.color % PLAYER_COLORS.length]
}

export function textOn(hex: string): string {
  const n = parseInt(hex.slice(1), 16)
  const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255
  return 0.299 * r + 0.587 * g + 0.114 * b > 150 ? '#111' : '#fff'
}

export function initials(name: string): string {
  const parts = name.trim().split(/\s+/)
  return (parts.length > 1 ? parts[0][0] + parts[1][0] : name.slice(0, 2)).toUpperCase()
}

/** Range is counted in cardinal steps (Manhattan distance). */
export function dist(a: Pick<Player, 'x' | 'y'>, b: Pick<Player, 'x' | 'y'>): number {
  return Math.abs(a.x! - b.x!) + Math.abs(a.y! - b.y!)
}

export function countdown(to: string | null, now: number): string {
  if (!to) return ''
  const ms = new Date(to).getTime() - now
  if (ms <= 0) return 'any moment'
  const m = Math.floor(ms / 60000)
  const h = Math.floor(m / 60)
  return h > 0 ? `${h}h ${m % 60}m` : `${m}m`
}

export function timeAgo(iso: string, now: number): string {
  const s = Math.max(0, Math.floor((now - new Date(iso).getTime()) / 1000))
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`
}
