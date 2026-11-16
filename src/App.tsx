import { useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { configured, supabase } from './lib/supabase'
import Auth, { NewPassword } from './components/Auth'
import Home from './components/Home'
import GameScreen from './components/GameScreen'

function useHashRoute() {
  const [hash, setHash] = useState(window.location.hash)
  useEffect(() => {
    const on = () => setHash(window.location.hash)
    window.addEventListener('hashchange', on)
    return () => window.removeEventListener('hashchange', on)
  }, [])
  return hash
}

export function goTo(path: string) {
  window.location.hash = path
}

export async function signOut() {
  await supabase.auth.signOut()
  goTo('/')
}

export default function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined)
  const [recovering, setRecovering] = useState(false)
  const hash = useHashRoute()

  useEffect(() => {
    if (!configured) return
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data } = supabase.auth.onAuthStateChange((event, s) => {
      setSession(s)
      if (event === 'PASSWORD_RECOVERY') setRecovering(true)
    })
    return () => data.subscription.unsubscribe()
  }, [])

  if (!configured) {
    return (
      <main className="center-page">
        <div className="card">
          <h1>Triple-T</h1>
          <p>Supabase isn't configured yet. Copy <code>.env.example</code> to <code>.env</code>, fill in your project URL and anon key, then restart the dev server.</p>
        </div>
      </main>
    )
  }
  if (session === undefined) return <main className="center-page"><p className="muted">Connecting…</p></main>
  // Accounts from the earlier anonymous version can't resume; ask them to sign up.
  if (!session || session.user.is_anonymous) return <Auth />
  if (recovering) return <NewPassword onDone={() => setRecovering(false)} />

  const match = hash.match(/^#\/game\/([0-9a-f-]{36})/)
  if (match) return <GameScreen key={match[1]} gameId={match[1]} userId={session.user.id} />
  const join = hash.match(/^#\/join\/([A-Za-z0-9]{6})/)
  const displayName = (session.user.user_metadata?.display_name as string | undefined) ?? ''
  return <Home initialCode={join?.[1].toUpperCase()} email={session.user.email ?? ''} displayName={displayName} />
}
