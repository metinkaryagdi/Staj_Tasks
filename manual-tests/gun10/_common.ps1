# Gün 10 script'lerinin ortak yardımcıları. Gün 8'in _common.ps1'ini de yükler (Gün 1-7 yardımcıları dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun8\_common.ps1"

# Veritabanı volume'lerini koşuya özel adla açar (compose.volumes.yml): her koşu boş veritabanıyla başlar, eski volume'ler
# silinmez. Önce/sonra karşılaştırmasında iki koşunun başlangıcı aynı olsun diye. Aynı volume'ü yeniden kullanmak, o
# koşunun verisini görmek demektir.
function Use-Gun10Volumes([Parameter(Mandatory)][string]$Volume) {
    $env:GUN10_VOL = $Volume
    $env:COMPOSE_FILE = (Join-Path $RepoRoot 'docker-compose.yml') + ';' + (Join-Path $PSScriptRoot 'compose.volumes.yml')
}

# Saniyeyi "X dk Y sn" olarak yazar (bir saati geçerse "X sa Y dk Z sn").
function Format-Duration([double]$Seconds) {
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalHours -ge 1) { '{0} sa {1} dk {2} sn' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds }
    else { '{0} dk {1} sn' -f $t.Minutes, $t.Seconds }
}
