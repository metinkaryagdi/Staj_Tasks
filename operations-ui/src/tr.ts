// Ekrandaki bütün metinler burada toplanır (API'den gelen durum adları zaten Türkçedir).
import { ApiError } from './api/client'
import type { ResendItem } from './api/types'
import { apiUrl } from './config'

export const tr = {
  appTitle: 'Fatura Operasyon Ekranı',
  nav: { summary: 'Özet', invoices: 'Fatura Listesi', reconciliation: 'Mutabakat' },
  stuckBadge: {
    label: (waited: string) => `Takılı · ${waited}`,
    hint: 'Özetteki takılı sayısına giriyor: bu durumda beklenenden uzun kaldı. Süre, son güncellemeden bu yana geçen zaman.',
    minutes: (n: number) => `${n} dk`,
    hours: (n: number) => `${n} sa`,
    days: (n: number) => `${n} gün`,
  },
  operator: {
    title: 'Adınız',
    hint:
      'Yeniden gönderme ve mutabakat başlatma işlemleri bu adla kaydedilir. Bu bir giriş değildir; ad yalnızca kayıt içindir ' +
      've bu tarayıcıda hatırlanır.',
    label: 'Ad soyad',
    submit: 'Devam et',
    invalid: (max: number) => `Bir ad yazın (en fazla ${max} karakter).`,
    current: (name: string) => `Kullanıcı: ${name}`,
    change: 'Değiştir',
  },
  common: {
    loading: 'Yükleniyor…',
    lastRefresh: 'Son yenileme',
    refreshNote: 'Bu sayfa 10 saniyede bir kendiliğinden yenilenir.',
    staleNote: 'Son bilinen veriler gösteriliyor.',
    empty: 'Kayıt yok.',
    yes: 'Evet',
    cancel: 'Vazgeç',
    notFoundTitle: 'Sayfa bulunamadı',
    backToSummary: 'Özet sayfasına dön',
    unexpectedError: 'Ekranda beklenmeyen bir hata oluştu.',
    reload: 'Sayfayı yenile',
  },
  summary: {
    title: 'Özet',
    statusCounts: 'Durumlara göre fatura sayısı',
    total: 'Toplam fatura',
    stuck: 'Takılı fatura',
    stuckHint: (minutes: number) => `Gönderildi ya da İşleme Alındı durumunda ${minutes} dakikadan uzun kalan faturalar.`,
    lastRun: 'Son mutabakat çalışması',
    noRun: 'Henüz mutabakat çalışması yok.',
    runNumber: 'Çalışma no',
    runStatus: 'Durum',
    started: 'Başlangıç',
    finished: 'Bitiş',
    stillRunning: 'Çalışıyor; sayılar bitince görünür.',
    checked: 'Kontrol edilen',
    fixed: 'Düzeltilen bulgu',
    reported: 'Raporlanan bulgu',
    error: 'Hata',
    openReconciliation: 'Mutabakat sayfasına git',
    queue: "ERP'ye gönderim kuyruğu",
    queued: 'Kuyrukta bekleyen',
    queuedHint: "ERP'ye gönderilmeyi bekleyen faturalar.",
    oldestWait: 'En eski bekleme',
    oldestWaitHint: 'Kuyruktaki en eski faturanın kuyruğa girdiğinden bu yana beklediği süre.',
    sentLastMinute: 'Son 1 dakikada gönderilen',
    sentLastMinuteHint: "ERP'nin son 60 saniyede kabul ettiği faturalar.",
    seconds: (s: number) => `${s} sn`,
    minutesSeconds: (m: number, s: number) => `${m} dk ${s} sn`,
    hoursMinutes: (h: number, m: number) => `${h} sa ${m} dk`,
  },
  invoices: {
    title: 'Fatura Listesi',
    statusFilter: 'Durum',
    allStatuses: 'Tüm durumlar',
    stuckOption: 'Takılı',
    search: 'Fatura numarası ara',
    searchPlaceholder: 'Örn. FTR-000123',
    pageSize: 'Sayfa başına',
    columns: {
      select: 'Seç',
      invoiceNumber: 'Fatura No',
      customerCode: 'Müşteri Kodu',
      amount: 'Tutar',
      status: 'Durum',
      attempts: 'Deneme Sayısı',
      lastError: 'Son Hata',
      updatedAt: 'Son Güncelleme',
      detail: 'Detay',
    },
    detailLink: 'Fatura Detayı',
    noMatch: 'Bu süzgece uyan fatura yok.',
    totalCount: (count: number) => `${count} fatura`,
    page: (page: number, pages: number) => `Sayfa ${page} / ${Math.max(pages, 1)}`,
    previous: 'Önceki',
    next: 'Sonraki',
    selectAllFailed: 'Bu sayfadaki Başarısız faturaların hepsini seç',
    nothingSelected: 'Toplu yeniden göndermek için Başarısız faturaların kutusunu işaretleyin.',
    selectedCount: (count: number, max: number) => `${count} fatura seçili (en fazla ${max})`,
    selectionLimit: (max: number) => `Tek seferde en fazla ${max} fatura seçilebilir.`,
    clearSelection: 'Seçimi temizle',
    bulkResend: 'Seçilenleri Yeniden Gönder',
    bulkConfirm: (count: number) => `${count} fatura yeniden gönderilmek üzere kuyruğa alınsın mı?`,
    bulkSending: 'Gönderiliyor…',
    bulkResultTitle: 'Toplu yeniden gönderme sonucu',
    bulkQueued: (count: number) => `${count} fatura kuyruğa alındı.`,
    bulkRefused: (count: number) => `${count} fatura kuyruğa alınamadı.`,
    refusedReason: 'Neden',
    dismiss: 'Kapat',
    watchQueue: 'Bekleme sırasını izle',
    selectOnlyFailed: 'Yalnızca Başarısız faturalar seçilebilir.',
  },
  details: {
    back: 'Fatura listesine dön',
    resend: 'Yeniden Gönder',
    resending: 'Gönderiliyor…',
    resendQueued: 'Fatura yeniden gönderilmek üzere kuyruğa alındı. Durumu bu sayfada izleyebilirsiniz.',
    followUpSection: 'Takip',
    takeFollowUp: 'Takibe Al',
    closeFollowUp: 'Takibi Kapat',
    saveFollowUp: 'Kaydet',
    followUpNote: 'Not',
    followUpPlaceholder: 'Bu faturayla ilgili kısa not',
    followUpOpened: 'Fatura takibe alındı.',
    followUpClosed: 'Takip kapatıldı.',
    followUpOpen: (name: string) => `Takipte: ${name}`,
    followUpNoLongerStuck: 'Takip açık, fatura artık takılı değil.',
    followUpHistory: 'Takip geçmişi',
    noFollowUps: 'Bu fatura için henüz takip kaydı yok.',
    followUpError: 'Takip işlemi yapılamadı.',
    followUpFields: { note: 'Not', operator: 'Açan', openedAt: 'Açılış', closedAt: 'Kapanış', closedBy: 'Kapatan' },
    invoiceSection: 'Fatura bilgileri',
    outboxSection: 'Gönderim kaydı (erp_outbox)',
    noOutbox: 'Bu faturanın gönderim kaydı yok.',
    eventsSection: 'ERP haberleri',
    noEvents: 'Bu fatura için henüz haber gelmedi.',
    findingsSection: 'Mutabakat bulguları',
    noFindings: 'Bu faturaya ait mutabakat bulgusu yok.',
    actionsSection: 'Müdahaleler',
    noActions: 'Bu faturaya ekrandan yapılmış bir müdahale yok.',
    actions: { createdAt: 'Zaman', operator: 'Kim', action: 'İşlem', result: 'Sonuç' },
    fields: {
      customerCode: 'Müşteri kodu',
      amount: 'Tutar',
      invoiceDate: 'Fatura tarihi',
      status: 'Durum',
      erpReference: 'ERP referansı',
      rejectReason: 'Ret nedeni',
      lastError: 'Son hata',
      attempts: 'Deneme sayısı (toplam)',
      createdAt: 'Oluşturulma',
      updatedAt: 'Son güncelleme',
      erpCheckedAt: "Mutabakatın ERP'ye son sorusu",
      erpCheckResult: 'ERP cevabı',
    },
    neverChecked: "Mutabakat tek tek sormadı: ERP'nin listesiyle karşılaştırılıyor. Gönderim ve ERP haberleri aşağıda.",
    outbox: {
      status: 'Kayıt durumu',
      attempts: 'Deneme sayısı',
      nextAttempt: 'Bir sonraki deneme',
      nextAttemptDone: 'Beklemede değil',
      lastError: 'Son hata',
      createdAt: 'Oluşturulma',
      processedAt: 'İşlenme',
    },
    events: {
      eventId: 'Haber No (event_id)',
      type: 'Tür',
      status: 'Durum',
      ignoreReason: 'Yok sayılma nedeni (ignore_reason)',
      deliveryCount: 'Kaç kez geldi',
      occurredAt: 'ERP\'de oluşma',
      receivedAt: 'Geliş',
      processedAt: 'Uygulanma',
    },
    findings: {
      run: 'Çalışma',
      type: 'Tür',
      action: 'İşlem',
      details: 'Ayrıntı',
      createdAt: 'Zaman',
    },
  },
  reconciliation: {
    title: 'Mutabakat',
    runNow: 'Mutabakatı Şimdi Çalıştır',
    starting: 'Başlatılıyor…',
    started: (id: number) => `Mutabakat başlatıldı (çalışma ${id}).`,
    runsSection: 'Çalışmalar',
    noRuns: 'Henüz mutabakat çalışması yok.',
    emptyPage: 'Bu sayfada çalışma yok.',
    totalCount: (count: number) => `${count} çalışma`,
    runColumns: {
      id: 'No',
      startedAt: 'Başlangıç',
      finishedAt: 'Bitiş',
      startedBy: 'Başlatan',
      status: 'Durum',
      checked: 'Kontrol edilen',
      fixed: 'Düzeltilen',
      reported: 'Raporlanan',
      error: 'Hata',
    },
    startedByUnknown: 'Bu çalışma, başlatanın kaydedilmesinden önce yapıldı.',
    findingsSection: (id: number) => `Çalışma ${id} bulguları`,
    reportedSection: 'Raporlanan bulgular',
    reportedHint: 'Servisin kendi başına düzeltemediği farklar; incelenmesi gerekir.',
    fixedSection: 'Düzeltilen bulgular',
    fixedHint: 'Mutabakatın kendiliğinden düzelttiği farklar.',
    noReported: 'Raporlanan bulgu yok.',
    noFixed: 'Düzeltilen bulgu yok.',
    findingColumns: { invoiceNumber: 'Fatura No', type: 'Tür', details: 'Ayrıntı', createdAt: 'Zaman' },
    selectRun: 'Bulgularını görmek için bir çalışma seçin.',
    runningNote: 'Çalışma sürüyor; bulgular geldikçe burada görünür.',
  },
} as const

const eventTypeLabels: Record<string, string> = {
  'invoice.received': 'Fatura alındı',
  'invoice.approved': 'Fatura onaylandı',
  'invoice.rejected': 'Fatura reddedildi',
}

export function eventTypeLabel(eventType: string): string {
  return eventTypeLabels[eventType] ?? eventType
}

// --- Hata mesajları ---------------------------------------------------------------------------------------------------

export function describeError(error: unknown): string {
  if (!(error instanceof ApiError)) return 'Beklenmeyen bir hata oluştu.'

  switch (error.kind) {
    case 'unreachable':
      return (
        `Fatura Servisi'ne ulaşılamıyor (${apiUrl}). Servis kapalı olabilir ya da bu ekrana erişim izni verilmemiş olabilir. ` +
        'Bağlantı kendiliğinden yeniden denenecek.'
      )
    case 'server':
      return `Fatura Servisi bir hata verdi (HTTP ${error.status}). Bir süre sonra kendiliğinden yeniden denenecek.`
    default:
      if (error.code === 'invoice_not_found') return 'Bu numaralı bir fatura bulunamadı.'
      if (error.code === 'operator_name_required' || error.code === 'operator_name_invalid') {
        return 'İşlem yapılmadı: Fatura Servisi işlemi yapanın adını kabul etmedi. Sayfayı yenileyip adınızı yeniden girin.'
      }
      if (error.status === 404) return 'Aranan kayıt bulunamadı.'
      return `Fatura Servisi isteği kabul etmedi (HTTP ${error.status}).`
  }
}

// Cevap alınamayan bir POST'ta işlemin yapılıp yapılmadığı bilinmez; mesaj bunu saklamaz.
const unknownOutcome =
  "Fatura Servisi'ne ulaşılamadı. İşlemin yapılıp yapılmadığı belli değil; faturanın güncel durumunu kontrol edin."

export function describeResendError(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.code === 'invoice_not_failed') {
      return (
        `Bu fatura artık Başarısız durumda değil, şu an "${error.currentStatus}" durumunda. ` +
        'Başka biri faturayı az önce yeniden göndermiş olabilir; yeniden gönderme yapılmadı.'
      )
    }
    if (error.kind === 'unreachable') return unknownOutcome
  }
  return describeError(error)
}

export function describeFollowUpError(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.code === 'invoice_not_stuck') return `Bu fatura artık takılı değil (${error.currentStatus ?? 'durumu değişti'}). Takip açılmadı.`
    if (error.code === 'follow_up_open') return 'Bu faturanın zaten açık bir takibi var. Sayfa güncellendiğinde takip bilgisi görünecek.'
    if (error.code === 'follow_up_not_open') return 'Bu faturada kapatılacak açık takip yok.'
    if (error.kind === 'unreachable') return unknownOutcome
  }
  return describeError(error)
}

export function describeStartRunError(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.code === 'reconciliation_running') {
      return 'Mutabakat zaten çalışıyor. Bitmesini bekleyin; sonuç aşağıdaki çalışma listesinde görünecek.'
    }
    if (error.kind === 'unreachable') return unknownOutcome
  }
  return describeError(error)
}

export function describeResendRefusal(item: ResendItem): string {
  switch (item.result) {
    case 'not_found':
      return 'Fatura bulunamadı.'
    case 'not_failed':
      return `Başarısız durumda değil, şu an "${item.currentStatus}". Başka biri yeniden göndermiş olabilir.`
    default:
      return 'Kuyruğa alınamadı: Fatura Servisi hata verdi.'
  }
}
