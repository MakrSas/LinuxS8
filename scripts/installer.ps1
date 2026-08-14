$ErrorActionPreference = 'Stop'

# Нативный Windows-запускатель. Сам ADB работает в Windows; только сборка
# arm64 Debian, если она нужна, будет передана installer.py в WSL2.
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Python = Get-Command py -ErrorAction SilentlyContinue
if ($null -eq $Python) {
    $Python = Get-Command python -ErrorAction SilentlyContinue
}
if ($null -eq $Python) {
    throw 'Не найден Python 3. Установите Python и повторите.'
}

& $Python.Source (Join-Path $Root 'scripts\installer.py') @args
exit $LASTEXITCODE
