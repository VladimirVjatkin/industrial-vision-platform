param(
    [Parameter(Mandatory = $true)][string]$Server,
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$SshKey,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$RemoteDirectory = '/var/backups/ivp-outbox'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination | Out-Null
}
$remote = "$User@$Server"
$files = & ssh -i $SshKey -o BatchMode=yes -o StrictHostKeyChecking=yes $remote "find '$RemoteDirectory' -maxdepth 1 -type f -name 'ivp-*.tar.zst.age' -printf '%f`n'"
if ($LASTEXITCODE -ne 0) { throw 'SSH listing failed' }
$latest = $files | Sort-Object -Descending | Select-Object -First 1
if (-not $latest) { throw 'No encrypted backup found' }
$target = Join-Path $Destination $latest
if (Test-Path -LiteralPath $target) { throw "Target already exists: $target" }
& scp -i $SshKey -o BatchMode=yes -o StrictHostKeyChecking=yes "${remote}:${RemoteDirectory}/$latest" $target
if ($LASTEXITCODE -ne 0) { throw 'SCP failed' }
$remoteHash = (& ssh -i $SshKey -o BatchMode=yes -o StrictHostKeyChecking=yes $remote "sha256sum '$RemoteDirectory/$latest'") -split ' ' | Select-Object -First 1
if ($LASTEXITCODE -ne 0) { throw 'Remote hash failed' }
$localHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
if ($localHash -ne $remoteHash) { throw 'Hash mismatch' }
Write-Output "Downloaded and checked: $target"
