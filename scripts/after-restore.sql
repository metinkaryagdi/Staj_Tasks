-- Yedekten geri dönüşte servis açılmadan önce çalışır (scripts/restore-invoice-db.sh). Yedek geride kaldığı için ERP
-- yedekten sonra alınmış kayıtları biliyor olabilir; bu iki adım ERP'de çift fatura oluşmasını önler.

-- Numara sayacı yedekle birlikte geri döndü: yeni fatura, yedekten sonra verilip ERP'ye ulaşmış bir numarayı almasın.
-- Atlama, iki yedek arasında alınabilecek fatura sayısından (saniyede 50 faturayla 5 dakikada 15.000) çok büyüktür.
SELECT setval('invoice_number_seq', (SELECT last_value FROM invoice_number_seq) + 1000000);

-- Gönderim kodu, hiç denenmemiş faturayı ERP'de olamaz sayıp sormadan gönderir. Yedekte böyle görünen fatura yedekten sonra
-- ERP'ye ulaşmış olabilir; ERP aynı numarayı yeniden kaydeder. Sayaç 1 olunca gönderilmeden önce ERP'ye sorulur.
UPDATE invoices SET send_attempt_count = 1 WHERE status = 'Bekliyor' AND send_attempt_count = 0;
