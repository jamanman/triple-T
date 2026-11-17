import { useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'

type Mode = 'signin' | 'signup' | 'forgot'

const redirectTo = () => window.location.origin + window.location.pathname

export default function Auth() {
  const [mode, setMode] = useState<Mode>('signin')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [info, setInfo] = useState<string | null>(null)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true); setError(null); setInfo(null)
    try {
      if (mode === 'signin') {
        const { error } = await supabase.auth.signInWithPassword({ email, password })
        if (error) throw error
      } else if (mode === 'signup') {
        if (!name.trim()) throw new Error('Pick a display name')
        const { data, error } = await supabase.auth.signUp({
          email, password,
          options: { data: { display_name: name.trim() }, emailRedirectTo: redirectTo() },
        })
        if (error) throw error
        if (!data.session) setInfo(`Check ${email} for a confirmation link, then come back and sign in.`)
      } else {
        const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: redirectTo() })
        if (error) throw error
        setInfo(`If ${email} has an account, a password reset link is on its way.`)
      }
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const switchTo = (m: Mode) => { setMode(m); setError(null); setInfo(null) }

  return (
    <main className="center-page">
      <form className="card auth" onSubmit={submit}>
        <h1>Triple-T</h1>
        <p className="muted small">
          {mode === 'signin' && 'Sign in to resume your games from any device.'}
          {mode === 'signup' && 'Create an account so you can play from any device.'}
          {mode === 'forgot' && "We'll email you a link to set a new password."}
        </p>

        {mode === 'signup' && (
          <label className="field">
            <span>Display name</span>
            <input value={name} maxLength={20} onChange={(e) => setName(e.target.value)} autoComplete="nickname" />
          </label>
        )}
        <label className="field">
          <span>Email</span>
          <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" />
        </label>
        {mode !== 'forgot' && (
          <label className="field">
            <span>Password</span>
            <input type="password" required minLength={6} value={password} onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === 'signup' ? 'new-password' : 'current-password'} />
          </label>
        )}

        <button className="primary wide" disabled={busy}>
          {mode === 'signin' ? 'Sign in' : mode === 'signup' ? 'Create account' : 'Send reset link'}
        </button>

        {error && <p className="error small">{error}</p>}
        {info && <p className="info small">{info}</p>}

        <div className="auth-links small">
          {mode !== 'signin' && <button type="button" className="link" onClick={() => switchTo('signin')}>Have an account? Sign in</button>}
          {mode !== 'signup' && <button type="button" className="link" onClick={() => switchTo('signup')}>New here? Create an account</button>}
          {mode === 'signin' && <button type="button" className="link" onClick={() => switchTo('forgot')}>Forgot password?</button>}
        </div>
      </form>
    </main>
  )
}

/** Shown after the user follows a password reset link. */
export function NewPassword({ onDone }: { onDone: () => void }) {
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true); setError(null)
    const { error } = await supabase.auth.updateUser({ password })
    setBusy(false)
    if (error) setError(error.message)
    else onDone()
  }

  return (
    <main className="center-page">
      <form className="card auth" onSubmit={submit}>
        <h2>Set a new password</h2>
        <label className="field">
          <span>New password</span>
          <input type="password" required minLength={6} value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" />
        </label>
        <button className="primary wide" disabled={busy}>Save password</button>
        {error && <p className="error small">{error}</p>}
      </form>
    </main>
  )
}
