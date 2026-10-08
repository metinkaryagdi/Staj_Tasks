# Gün 8 (Yoğun Dönem) script'lerinin ortak yardımcıları. Gün 7'nin _common.ps1'ini de yükler (Gün 1-6 yardımcıları
# dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun7\_common.ps1"

# Restart-Simulator'ın her seferinde temizlediği değişkenlere hız sınırı da eklenir.
$SimulatorEnvKeys += 'RateLimit__PermitsPerSecond'

# k6 sabit sürümlü imajla, compose'un apps ağında çalışır: simülatöre ve servise container adlarıyla gider.
$K6Image = 'grafana/k6:1.3.0'
$K6Network = 'staj-tasks_apps'

# manual-tests\gun8\k6 içindeki script'i çalıştırır; $Env ortam değişkenleri k6'ya __ENV olarak geçer. Script'in
# handleSummary ile /out'a yazdığı dosyalar manual-tests\output'a düşer. k6'nın ekran çıktısını döner.
function Invoke-K6([string]$Script, [hashtable]$Env = @{}) {
    $arguments = @('run', '--rm', '--network', $K6Network,
        '-v', "$PSScriptRoot\k6:/scripts:ro", '-v', "${OutputDir}:/out")
    foreach ($key in $Env.Keys) { $arguments += @('-e', "$key=$($Env[$key])") }
    $arguments += @($K6Image, 'run', '--quiet', "/scripts/$Script")

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & docker @arguments 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) {
            $output | ForEach-Object { Write-Host $_ -ForegroundColor Red }
            throw "k6 $Script başarısız oldu (çıkış kodu $LASTEXITCODE)."
        }
    }
    finally { $ErrorActionPreference = $previous }
    $output
}

# Simülatör logunun verilen UTC anından (yyyy-MM-dd HH:mm:ss) sonraki satırları.
function Get-SimulatorLogSince([string]$FromUtc) {
    @(Get-SimulatorLog | ForEach-Object { "$_" } | Where-Object { $_.Length -ge 19 -and $_.Substring(0, 19) -ge $FromUtc })
}

# k6 script'inin handleSummary ile yazdığı özet. -Encoding UTF8 şart: PowerShell 5.1 aksi halde ANSI okur ve Türkçe
# kontrol adları ("hız", "meşgul") bozulur, adla yapılan aramalar boş döner.
function Read-K6Summary([string]$File) {
    Get-Content (Join-Path $OutputDir $File) -Raw -Encoding UTF8 | ConvertFrom-Json
}

# Özetteki, adı verilen kalıba uyan tek kontrol; bulunamazsa hata (sessizce 0 sayılmasın).
function Get-K6Check($Summary, [string]$Like) {
    $found = @($Summary.checks | Where-Object { $_.name -like $Like })
    if ($found.Count -ne 1) { throw "k6 özetinde '$Like' kalıbına uyan $($found.Count) kontrol var (1 bekleniyordu)." }
    $found[0]
}
