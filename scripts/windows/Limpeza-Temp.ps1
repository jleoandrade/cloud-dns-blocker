<#
.SYNOPSIS
    Limpeza de pastas temporarias, logs, caches e reset do Windows Update na maquina LOCAL.

.DESCRIPTION
    Pensado para ser copiado/enviado para a maquina e executado nela (manualmente,
    via Intune/RMM, GPO ou Invoke-Command -FilePath). Tudo e feito sobre a
    propria maquina onde o script roda.

    Etapas:
      1. Pastas temporarias (Windows\Temp, Temp de todos os perfis, TEMP da sessao) e Prefetch
      2. Logs do Windows Update / CBS
      3. Varredura de *.tmp em pastas conhecidas
      4. Fila de impressao (spooler)
      5. Windows Error Reporting
      6. Reset do Windows Update + DISM StartComponentCleanup
      7. Verificacao de saude do Windows Update

    As pastas sao ESVAZIADAS (o conteudo e apagado, a pasta e mantida), para preservar
    as permissoes (ACL) originais de pastas como C:\Windows\Temp e spool\PRINTERS.

.PARAMETER SkipPrefetch
    Nao limpa C:\Windows\Prefetch.
.PARAMETER SkipPrintQueue
    Nao para o spooler nem limpa a fila de impressao.
.PARAMETER SkipWindowsUpdateReset
    Nao para os servicos nem apaga SoftwareDistribution/catroot2.
.PARAMETER SkipDism
    Nao executa DISM /StartComponentCleanup (etapa mais demorada).
.PARAMETER LogPath
    Pasta onde o log (transcript) sera gravado. Padrao: C:\ProgramData\LimpezaTemp

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Limpeza-Temp.ps1

.EXAMPLE
    # Rodando a partir de outra maquina, executando NA maquina destino:
    Invoke-Command -ComputerName PC01 -FilePath .\Limpeza-Temp.ps1

.NOTES
    Requer execucao como Administrador (ou SYSTEM). Compativel com Windows PowerShell 5.1.
    Codigos de saida: 0 = sucesso, 1 = sem privilegio de administrador, 2 = concluido com avisos.
#>
[CmdletBinding()]
param(
    [switch]$SkipPrefetch,
    [switch]$SkipPrintQueue,
    [switch]$SkipWindowsUpdateReset,
    [switch]$SkipDism,
    [string]$LogPath = "$env:ProgramData\LimpezaTemp"
)

# ---------------------------------------------------------------------------
# 0. Pre-requisitos
# ---------------------------------------------------------------------------

# Se iniciado por um host 32 bits em Windows 64 bits,
# System32 seria redirecionado para SysWOW64. Relanca em PowerShell 64 bits.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $ps64) {
        $argList = @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', "`"$PSCommandPath`"")
        foreach ($k in $PSBoundParameters.Keys) {
            $v = $PSBoundParameters[$k]
            if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
            else { $argList += "-$k"; $argList += "`"$v`"" }
        }
        $p = Start-Process -FilePath $ps64 -ArgumentList $argList -Wait -PassThru -NoNewWindow
        exit $p.ExitCode
    }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Este script precisa ser executado como Administrador."
    exit 1
}

$ErrorActionPreference = 'Continue'
$script:Warnings = 0

New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
$logFile = Join-Path $LogPath ("Limpeza_{0}_{1:yyyyMMdd_HHmmss}.log" -f $env:COMPUTERNAME, (Get-Date))
Start-Transcript -Path $logFile -Force | Out-Null

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host ("[{0:HH:mm:ss}] === {1} ===" -f (Get-Date), $msg) -ForegroundColor Cyan
}

function Write-Info([string]$msg) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg)
}

function Write-Warn([string]$msg) {
    $script:Warnings++
    Write-Host ("[{0:HH:mm:ss}] AVISO: {1}" -f (Get-Date), $msg) -ForegroundColor Yellow
}

function Get-FreeSpaceGB {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    [math]::Round($d.FreeSpace / 1GB, 2)
}

# Apaga a pasta inteira (usado onde a pasta pode deixar de existir: caches/filas descartaveis).
function Fast-Delete([string]$path) {
    if (Test-Path -LiteralPath $path) {
        Write-Info "Removendo pasta: $path"
        cmd.exe /c "rmdir /s /q `"$path`"" 2>$null
    }
}

# Esvazia a pasta mantendo-a (e mantendo a ACL). Arquivos em uso sao ignorados.
function Clear-Folder([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    Write-Info "Esvaziando: $path"
    # Arquivos soltos (rapido via cmd; /a remove tambem ocultos/sistema/somente-leitura)
    cmd.exe /c "del /f /s /q /a `"$path\*`"" 2>$null | Out-Null
    # Subpastas
    Get-ChildItem -LiteralPath $path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        cmd.exe /c "rmdir /s /q `"$($_.FullName)`"" 2>$null
    }
}

function Remove-Files([string]$pattern) {
    Get-ChildItem -Path $pattern -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Stop-Svc([string[]]$names) {
    foreach ($n in $names) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Stopped') {
            Write-Info "Parando servico $n"
            try { Stop-Service -Name $n -Force -ErrorAction Stop }
            catch { Write-Warn "Falha ao parar ${n}: $($_.Exception.Message)" }
        }
    }
}

function Start-Svc([string[]]$names) {
    foreach ($n in $names) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s -and $s.StartType -ne 'Disabled' -and $s.Status -ne 'Running') {
            Write-Info "Iniciando servico $n"
            try { Start-Service -Name $n -ErrorAction Stop }
            catch { Write-Warn "Falha ao iniciar ${n}: $($_.Exception.Message)" }
        }
    }
}

$freeBefore = Get-FreeSpaceGB
$start      = Get-Date
Write-Host "Maquina: $env:COMPUTERNAME | Usuario: $env:USERDOMAIN\$env:USERNAME | Livre em ${env:SystemDrive}: $freeBefore GB"
Write-Host "Log: $logFile"

# Perfis de usuario reais (ignora Public, Default, All Users etc.)
$userProfiles = Get-ChildItem "$env:SystemDrive\Users" -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') -and
                   -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }
$userTemps = $userProfiles | ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' }

$WindowsUpdateHealthy = $false
$spoolerWasRunning    = (Get-Service spooler -ErrorAction SilentlyContinue).Status -eq 'Running'

try {
    # -----------------------------------------------------------------------
    # 1. Pastas temporarias e Prefetch
    # -----------------------------------------------------------------------
    Write-Step "1. Pastas temporarias"
    Clear-Folder "$env:windir\Temp"
    foreach ($t in $userTemps) { Clear-Folder $t }
    if ($env:TEMP -and ($userTemps -notcontains $env:TEMP)) { Clear-Folder $env:TEMP }   # TEMP da conta que executa (ex.: SYSTEM)

    if (-not $SkipPrefetch) { Clear-Folder "$env:windir\Prefetch" }

    # -----------------------------------------------------------------------
    # 2. Logs
    # -----------------------------------------------------------------------
    Write-Step "2. Logs do Windows Update / CBS"
    Remove-Files "$env:windir\WindowsUpdate.log"
    Remove-Files "$env:windir\SoftwareDistribution\ReportingEvents.log"
    Remove-Files "$env:windir\Logs\CBS\*.log"
    Remove-Files "$env:windir\Logs\CBS\*.cab"

    # -----------------------------------------------------------------------
    # 3. Varredura de *.tmp (o que sobrou por estar em uso, ou em outras pastas)
    # -----------------------------------------------------------------------
    Write-Step "3. Varredura de *.tmp"
    $paths = @("$env:windir\Temp", "$env:ProgramData\Temp") + $userTemps
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            Get-ChildItem -LiteralPath $p -Recurse -Force -File -Filter *.tmp -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }

    # -----------------------------------------------------------------------
    # 4. Fila de impressao
    # -----------------------------------------------------------------------
    if (-not $SkipPrintQueue) {
        Write-Step "4. Fila de impressao"
        Stop-Svc 'spooler'
        Clear-Folder "$env:windir\System32\spool\PRINTERS"
        if ($spoolerWasRunning) { Start-Svc 'spooler' }
    }

    # -----------------------------------------------------------------------
    # 5. Windows Error Reporting
    # -----------------------------------------------------------------------
    Write-Step "5. Windows Error Reporting"
    Fast-Delete "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
    Fast-Delete "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
    Fast-Delete "$env:ProgramData\Microsoft\Windows\WER\Temp"

    # -----------------------------------------------------------------------
    # 6. Reset do Windows Update + limpeza de componentes
    # -----------------------------------------------------------------------
    if (-not $SkipWindowsUpdateReset) {
        Write-Step "6a. Reset do Windows Update"
        $wuServices = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
        Stop-Svc $wuServices
        Start-Sleep -Seconds 2
        Fast-Delete "$env:windir\SoftwareDistribution"
        Fast-Delete "$env:windir\System32\catroot2"
        if (Test-Path "$env:windir\SoftwareDistribution") { Write-Warn "SoftwareDistribution nao foi removida por completo (arquivos em uso)." }
        Start-Svc $wuServices
        Start-Sleep -Seconds 3
    }

    if (-not $SkipDism) {
        Write-Step "6b. DISM /StartComponentCleanup (pode levar varios minutos)"
        & "$env:windir\System32\Dism.exe" /Online /Cleanup-Image /StartComponentCleanup /NoRestart
        if ($LASTEXITCODE -ne 0) { Write-Warn "DISM retornou codigo $LASTEXITCODE." }
    }

    # -----------------------------------------------------------------------
    # 7. Verificacao de saude do Windows Update
    # -----------------------------------------------------------------------
    Write-Step "7. Saude do Windows Update"
    try {
        $sess   = New-Object -ComObject Microsoft.Update.Session
        $result = $sess.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
        $WindowsUpdateHealthy = $true
        Write-Info "Windows Update OK - $($result.Updates.Count) atualizacao(oes) pendente(s)."
    }
    catch {
        Write-Warn "Falha na consulta ao Windows Update: $($_.Exception.Message)"
    }
}
finally {
    # Garante que nenhum servico fique parado caso algo de errado no meio
    if (-not $SkipPrintQueue -and $spoolerWasRunning) { Start-Svc 'spooler' }
    if (-not $SkipWindowsUpdateReset) { Start-Svc 'wuauserv', 'bits', 'cryptsvc' }

    $freeAfter = Get-FreeSpaceGB
    $elapsed   = (Get-Date) - $start

    Write-Host ""
    Write-Host "================ RESUMO ================" -ForegroundColor Green
    Write-Host ("Livre antes : {0} GB" -f $freeBefore)
    Write-Host ("Livre depois: {0} GB" -f $freeAfter)
    Write-Host ("Liberado    : {0} GB" -f [math]::Round($freeAfter - $freeBefore, 2))
    Write-Host ("Duracao     : {0:mm\:ss}" -f $elapsed)
    Write-Host ("WU saudavel : {0}" -f $WindowsUpdateHealthy)
    Write-Host ("Avisos      : {0}" -f $script:Warnings)
    Write-Host "Log         : $logFile"

    Stop-Transcript | Out-Null
}

if ($script:Warnings -gt 0) { exit 2 } else { exit 0 }
