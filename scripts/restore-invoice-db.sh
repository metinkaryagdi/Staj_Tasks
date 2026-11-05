#!/usr/bin/env bash
# Fatura Servisi veritabanını yedekten geri döndürür. Onay sormaz; varsa mevcut veritabanının içeriğini siler. Ne zaman
# çalıştırılacağı: FELAKET-KITAPCIGI.md.
#   scripts/restore-invoice-db.sh                                 en yeni yedek
#   scripts/restore-invoice-db.sh invoice_20261105T101500Z.dump   yedek klasöründeki belirli bir dosya
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1   # Git Bash container içi yolları Windows yoluna çevirmesin

backups="${INVOICE_BACKUP_DIR:-./backups/invoice-db}"
file="${1:-$(cd "$backups" && ls -1 invoice_*.dump 2>/dev/null | sort | tail -n 1 || true)}"
if [ -z "$file" ] || [ ! -f "$backups/$file" ]; then
    echo "Yedek bulunamadi: $backups/$file" >&2
    exit 1
fi
echo "Kullanilan yedek: $file"

in_backup_container() { docker compose run --rm --no-deps -T invoice-db-backup "$@"; }

echo "1/6 Servisler ve yedek servisi durduruluyor"
docker compose stop invoice-service invoice-db-backup

echo "2/6 Veritabani bos olarak kuruluyor"
docker compose up -d --wait invoice-db
in_backup_container psql -d postgres -v ON_ERROR_STOP=1 \
    -c 'DROP DATABASE IF EXISTS invoice_service WITH (FORCE)' -c 'CREATE DATABASE invoice_service'

echo "3/6 Yedek yukleniyor"
in_backup_container pg_restore --no-owner --no-privileges --exit-on-error -d invoice_service "/backups/$file"

echo "4/6 Migration ve uygulama kullanicisi"
docker compose run --rm --no-deps -T invoice-migrate

echo "5/6 Numara sayaci ve bekleyen faturalar"
in_backup_container psql -v ON_ERROR_STOP=1 -f /scripts/after-restore.sql

echo "6/6 Servisler aciliyor"
docker compose up -d --no-deps invoice-service invoice-db-backup

echo "Geri donus tamam. Yedek: $file"
in_backup_container psql -At -c "SELECT 'Fatura: ' || count(*) || ', kuyrukta: ' || (SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor') FROM invoices"
