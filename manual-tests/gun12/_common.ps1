# Gün 12 script'lerinin ortak yardımcıları. Gün 11'in _common.ps1'ini de yükler (Gün 1-11 yardımcıları dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun11\_common.ps1"

# Kontrol listesi boş veritabanıyla başlar: compose bu güne özel volume'lerle açılır (staj-tasks_*-db-data-gun12); eski
# volume'ler silinmez, dokunulmaz.
Use-Gun10Volumes 'gun12'
