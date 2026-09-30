# Elle testler

Kontrol listeleri güne göre ayrılmıştır. Hepsi repo kök klasöründen PowerShell ile çalıştırılır
(önce `docker compose up -d --build`).

| Klasör | Konu | İçerik |
|---|---|---|
| [`gun1/`](gun1/README.md) | ERP Simülatörü | 7 madde (`1-hata-yok.ps1` … `7-sorgu.ps1`), `db.ps1` (simülatör veritabanı), `loglar.ps1` (simülatör logları) |
| [`gun2/`](gun2/README.md) | Fatura Servisi | 6 madde (`1-oran-toplami.ps1` … `6-gec-cevap.ps1`), `karsilastir.ps1` (servis ↔ simülatör karşılaştırması) |

Ortak yardımcılar `gun1/_common.ps1` içindedir; `gun2/_common.ps1` onu yükleyip Fatura Servisi yardımcılarını ekler.
Script çıktıları (log kayıtları, fatura aralıkları) `output/` altına yazılır ve git'e girmez.
