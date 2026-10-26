# Kontrol listesi 3: rol kontrolü ve audience kontrolü koddan geçici olarak kaldırılınca hangi testlerin hangi hatayla kırıldığı.
# Her mutasyon ayrı koşudur: AuthExtensions.cs'te tek satır değiştirilir, bütün entegrasyon testleri koşulur, dosya geri alınır.
# Rapor her mutasyon için manual-tests/output/gun19-3-mutasyon-<ad>.txt. Docker açık olmalı; dört koşu ~10 dk.
#   .\manual-tests\gun19\3-mutasyon.ps1                 (dördü)
#   .\manual-tests\gun19\3-mutasyon.ps1 -Sadece audience
param([ValidateSet('okuma', 'mudahale', 'olusturma', 'audience')][string[]]$Sadece)
. "$PSScriptRoot\_common.ps1"

$file = Join-Path $RepoRoot 'invoice-service\src\InvoiceService.Api\Auth\AuthExtensions.cs'
$project = Join-Path $RepoRoot 'invoice-service\tests\InvoiceService.IntegrationTests'

# Ad, değiştirilen satır, yerine yazılan satır.
$mutations = [ordered]@{
    okuma     = @('options.AddPolicy(Policies.Read, p => p.RequireRole(Roles.Viewer, Roles.Operator));',
                  'options.AddPolicy(Policies.Read, p => p.RequireAuthenticatedUser());')
    mudahale  = @('options.AddPolicy(Policies.Intervene, p => p.RequireRole(Roles.Operator));',
                  'options.AddPolicy(Policies.Intervene, p => p.RequireAuthenticatedUser());')
    olusturma = @('options.AddPolicy(Policies.CreateInvoice, p => p.RequireRole(Roles.InvoiceCreator));',
                  'options.AddPolicy(Policies.CreateInvoice, p => p.RequireAuthenticatedUser());')
    audience  = @('options.Audience = settings.Audience;',
                  'options.Audience = settings.Audience; options.TokenValidationParameters.ValidateAudience = false;')
}

$original = [IO.File]::ReadAllText($file)
foreach ($name in $mutations.Keys) {
    if ($Sadece -and $name -notin $Sadece) { continue }
    $before, $after = $mutations[$name]
    if (-not $original.Contains($before)) { throw "AuthExtensions.cs'te bulunamadı: $before" }

    New-Report "gun19-3-mutasyon-$name"
    Write-Title "Kontrol listesi 3) Mutasyon: $name"
    Write-Line "Dosya: invoice-service/src/InvoiceService.Api/Auth/AuthExtensions.cs"
    Write-Line "Önce:  $before"
    Write-Line "Sonra: $after"
    $trx = Join-Path ([IO.Path]::GetTempPath()) "gun19-mutasyon-$name.trx"
    Remove-Item $trx -ErrorAction SilentlyContinue
    try {
        [IO.File]::WriteAllText($file, $original.Replace($before, $after))
        $watch = [Diagnostics.Stopwatch]::StartNew()
        & dotnet test $project --logger "trx;LogFileName=$trx" *> $null
        $watch.Stop()
    }
    finally { [IO.File]::WriteAllText($file, $original) }

    [xml]$xml = Get-Content -Raw -Encoding UTF8 $trx
    $ns = @{ t = 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010' }
    $results = @(Select-Xml -Xml $xml -XPath '//t:UnitTestResult' -Namespace $ns | ForEach-Object { $_.Node })
    $failed = @($results | Where-Object { $_.outcome -eq 'Failed' })
    Write-Line ("Koşu: {0} test, {1} geçti, {2} kırıldı ({3:N0} sn). Kod geri alındı." -f $results.Count,
        ($results.Count - $failed.Count), $failed.Count, $watch.Elapsed.TotalSeconds)
    Write-Line ''
    Write-Line 'Kırılan testler ve hata:'
    foreach ($r in $failed | Sort-Object testName) {
        $message = (($r.Output.ErrorInfo.Message -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' | ')
        Write-Line "  - $($r.testName)"
        Write-Line "      $message"
    }
    Save-Report
}

$restored = [IO.File]::ReadAllText($file) -eq $original
Write-Host "AuthExtensions.cs geri alındı: $restored"
