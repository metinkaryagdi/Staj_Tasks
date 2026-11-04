// Fatura detayındaki iptal düğmesinin hali; servisin kurallarıyla aynı, servis yine de kendisi denetler.
export type CancelAction = 'cancel' | 'retry' | 'closed'

export function cancelAction(invoiceStatus: string, cancellationStatus: string | null): CancelAction {
  if (invoiceStatus === 'Reddedildi' || invoiceStatus === 'İptal Edildi') return 'closed'
  if (cancellationStatus === null) return 'cancel'
  return cancellationStatus === 'Başarısız' ? 'retry' : 'closed'
}
