import { useEffect, useRef } from 'react'

export interface ConfirmOptions {
  title: string
  detail?: string
  confirmLabel: string
  danger?: boolean
}

interface Props extends ConfirmOptions {
  onAnswer: (ok: boolean) => void
}

/** Modal "are you sure?" box. Enter confirms, Escape or clicking outside cancels. */
export default function ConfirmDialog({ title, detail, confirmLabel, danger, onAnswer }: Props) {
  const confirmRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    confirmRef.current?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { e.preventDefault(); onAnswer(false) }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onAnswer])

  return (
    <div className="modal-backdrop" onClick={() => onAnswer(false)}>
      <div className="modal card" role="alertdialog" aria-modal="true" aria-labelledby="confirm-title"
        aria-describedby={detail ? 'confirm-detail' : undefined} onClick={(e) => e.stopPropagation()}>
        <h2 id="confirm-title">{title}</h2>
        {detail && <p id="confirm-detail" className="muted">{detail}</p>}
        <div className="row modal-actions">
          <button onClick={() => onAnswer(false)}>Cancel</button>
          <button ref={confirmRef} className={danger ? 'danger' : 'primary'} onClick={() => onAnswer(true)}>{confirmLabel}</button>
        </div>
      </div>
    </div>
  )
}
