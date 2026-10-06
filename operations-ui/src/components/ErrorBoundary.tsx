import { Component, type ReactNode } from 'react'
import { tr } from '../tr'

// Ekranın kendi kodundaki beklenmeyen bir hata beyaz sayfa bırakmasın. (Fatura Servisi'ne ulaşılamaması bu değildir:
// o, sorguların hata durumuyla sayfalarda gösterilir.)
export class ErrorBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }

  static getDerivedStateFromError() {
    return { failed: true }
  }

  render() {
    if (!this.state.failed) return this.props.children
    return (
      <div className="notice notice-error" role="alert">
        <p>{tr.common.unexpectedError}</p>
        <button type="button" onClick={() => window.location.reload()}>
          {tr.common.reload}
        </button>
      </div>
    )
  }
}
