#!/bin/sh
# invoice-db-backup container'ında çalışır (docker-compose.yml): BACKUP_INTERVAL_SECONDS'ta bir yedek alır, en yeni
# BACKUP_KEEP_FILES dosyayı tutar. Bağlantı bilgisi PG* ortam değişkenlerinden gelir.

trap 'exit 0' TERM INT

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

take_backup() {
    # Fatura yoksa yedek alınmaz: veritabanı kaybından sonra boş kurulan bir veritabanının yedekleri, saklama sınırıyla
    # sağlam yedekleri silmesin. Veritabanına ulaşılamazsa da eski yedeklere dokunulmaz.
    if ! count=$(psql -Atc "SELECT count(*) FROM invoices" 2>&1); then
        log "yedek alinamadi: $count"
        return
    fi
    if [ "$count" = "0" ]; then
        log "yedek alinmadi: fatura yok"
        return
    fi

    name="invoice_$(date -u +%Y%m%dT%H%M%SZ).dump"
    tmp="/backups/.$name.tmp"
    started=$(date +%s)
    # Dosya önce geçici adla yazılır, okunabildiği görülünce adını alır: yarım kalan yedek son yedek sayılmaz. Rol ve
    # yetki taşınmaz, onları geri dönüşte invoice-migrate yeniden verir.
    if pg_dump -Fc --no-owner --no-privileges -f "$tmp" && pg_restore --list "$tmp" > /dev/null; then
        mv "$tmp" "/backups/$name"
        log "yedek alindi: $name fatura=$count sure=$(($(date +%s) - started))sn boyut=$(wc -c < "/backups/$name")bayt"
        # Yalnız başarılı yedekten sonra silinir; dosya adları zamana göre sıralıdır.
        ls -1 /backups/invoice_*.dump | sort -r | tail -n +"$((BACKUP_KEEP_FILES + 1))" | xargs -r rm -f --
    else
        rm -f "$tmp"
        log "yedek alinamadi: pg_dump hata verdi"
    fi
}

while :; do
    take_backup
    sleep "$BACKUP_INTERVAL_SECONDS" &
    wait $!
done
