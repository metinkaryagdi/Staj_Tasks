import { useState, type FormEvent, type ReactNode } from 'react'
import { maxNameLength, normalizeName, setOperatorName, useOperatorName } from '../operator'
import { tr } from '../tr'

// Ad alınmadan ekran açılmaz; alındıktan sonra bir daha sorulmaz.
export function OperatorGate({ children }: { children: ReactNode }) {
  const name = useOperatorName()
  const [input, setInput] = useState('')
  const [invalid, setInvalid] = useState(false)

  if (name !== null) return <>{children}</>

  function submit(event: FormEvent) {
    event.preventDefault()
    const normalized = normalizeName(input)
    if (normalized === null) {
      setInvalid(true)
      return
    }
    setOperatorName(normalized)
  }

  return (
    <form className="operator-form" onSubmit={submit}>
      <h1>{tr.operator.title}</h1>
      <p className="muted">{tr.operator.hint}</p>
      <label>
        {tr.operator.label}
        <input
          type="text"
          autoFocus
          value={input}
          maxLength={maxNameLength}
          onChange={(e) => {
            setInput(e.target.value)
            setInvalid(false)
          }}
        />
      </label>
      {invalid && <p className="field-error">{tr.operator.invalid(maxNameLength)}</p>}
      <button type="submit" className="primary">
        {tr.operator.submit}
      </button>
    </form>
  )
}
