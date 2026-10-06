// Durum adından bir renk sınıfı seçer; bilinmeyen bir durum (ya da çalışma/outbox durumu) nötr görünür.
const tones: Record<string, string> = {
  Bekliyor: 'warn',
  Gönderildi: 'info',
  'İşleme Alındı': 'info',
  Onaylandı: 'ok',
  Reddedildi: 'bad',
  Başarısız: 'bad',
  Çalışıyor: 'info',
  Tamamlandı: 'ok',
  İşlendi: 'ok',
  'Yok Sayıldı': 'neutral',
  Düzeltildi: 'ok',
  Raporlandı: 'warn',
}

export function StatusBadge({ status }: { status: string }) {
  return <span className={`badge badge-${tones[status] ?? 'neutral'}`}>{status}</span>
}
