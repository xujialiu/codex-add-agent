[CmdletBinding()]
param(
    [string] $CodexExe,
    [string] $GptModel,
    [ValidateRange(1024, 65535)] [int] $Port = 60069,
    [string] $PiAuthFile,
    [string] $ProviderKeyFile,
    [string] $ProviderBase = 'https://open.bigmodel.cn/api/v1',
    [string] $ProviderCatalog
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $ProviderCatalog) { $ProviderCatalog = Join-Path $repo 'router\glm-5.3-flash.json' }
$node = (Get-Command node.exe -ErrorAction Stop).Source
$standardCodexDir = Join-Path $env:USERPROFILE '.codex'
$codexHomePath = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { $standardCodexDir }
$codexDir = (Resolve-Path -LiteralPath $codexHomePath).Path
$usesOrcaConfigMirror = $env:ORCA_CODEX_HOME -and $codexDir -ne $standardCodexDir -and
    [IO.Path]::GetFullPath($env:ORCA_CODEX_HOME).TrimEnd('\') -eq $codexDir.TrimEnd('\')
$configDir = if ($usesOrcaConfigMirror) { $standardCodexDir } else { $codexDir }
$installDir = Join-Path $codexDir 'model-router'

if ($installDir.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase) -or $installDir -eq $repo) {
    throw 'Use a Codex home outside the repository for this installation.'
}
if (-not $CodexExe) {
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($command) { $CodexExe = $command.Source }
}
if (-not $CodexExe) {
    $shim = Get-Command codex.cmd -ErrorAction SilentlyContinue
    $packageRoot = if ($env:CODEX_MANAGED_PACKAGE_ROOT) { $env:CODEX_MANAGED_PACKAGE_ROOT }
        elseif ($shim) { Join-Path (Split-Path $shim.Source) 'node_modules\@openai\codex' }
    if ($packageRoot) {
        $scopes = @((Join-Path $packageRoot 'node_modules\@openai'), (Split-Path $packageRoot))
        $platformPackages = foreach ($scope in $scopes) {
            Get-ChildItem -LiteralPath $scope -Filter 'codex-win32-*' -Directory -ErrorAction SilentlyContinue
        }
        $CodexExe = $platformPackages | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Filter 'codex.exe' -File -Recurse
        } | Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $CodexExe) { throw 'Pass the full path to your Codex CLI executable with -CodexExe.' }
$codex = (Resolve-Path -LiteralPath $CodexExe).Path
$version = & $codex --version
if ($LASTEXITCODE -ne 0) { throw 'Could not run the selected Codex binary.' }
$loginStatus = (& {
    $ErrorActionPreference = 'Continue'
    & $codex login status 2>&1
} | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Sign into the target Codex account first.' }
$authMode = if ($loginStatus -match 'ChatGPT') { 'chatgpt' }
    elseif ($loginStatus -match 'API key') { 'api-key' }
    else { throw 'Could not identify the target account authentication mode.' }
if ($env:OPENAI_BASE_URL -or $env:CODEX_BASE_URL) { throw 'The launch environment already overrides Codex routing.' }

$authFile = Join-Path $codexDir 'auth.json'
if (-not (Test-Path -LiteralPath $authFile -PathType Leaf)) {
    throw 'The isolated live trial requires file-backed Codex sign-in in the selected home.'
}
$upstream = [uri] $ProviderBase
if (-not $upstream.IsAbsoluteUri -or $upstream.Scheme -ne 'https' -or $upstream.UserInfo -or $upstream.Query -or $upstream.Fragment) {
    throw 'Use the provider''s trusted HTTPS Responses base URL without a query, fragment, or credential.'
}
$providerCatalogPath = (Resolve-Path -LiteralPath $ProviderCatalog).Path
$providerModels = ([IO.File]::ReadAllText($providerCatalogPath) | ConvertFrom-Json).models
if (@($providerModels).Count -ne 1 -or -not $providerModels.slug -or $providerModels.visibility -ne 'list' -or
    ($authMode -eq 'api-key' -and -not $providerModels.supported_in_api)) {
    throw 'Provide a catalog with exactly one visible third-party model for the target auth mode.'
}
if ($ProviderKeyFile -and $PiAuthFile) { throw 'Choose either -ProviderKeyFile or -PiAuthFile.' }
if (-not $ProviderKeyFile -and ($ProviderBase -cne 'https://open.bigmodel.cn/api/v1' -or $providerModels.slug -cne 'glm-5.3-flash')) {
    throw 'The Pi credential is for BigModel Coding Plan and glm-5.3-flash. Use -ProviderKeyFile for another provider.'
}
$providerModel = $providerModels.slug
$hash = [Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($codexDir.ToUpperInvariant()))
$taskName = 'Codex model router ' + ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 12).ToLowerInvariant())
if ((Test-Path -LiteralPath $installDir) -or (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    throw "An installation or scheduled task already exists for this Codex home. Review $installDir and '$taskName' first."
}
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    throw 'The selected router port is occupied. Choose another port with -Port.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$configPath = Join-Path $configDir 'config.toml'
$keyPath = Join-Path $installDir 'provider.key'
$routerConfigPath = Join-Path $installDir 'router.json'
$nodeRouter = Join-Path $installDir 'router.mjs'
$launcher = Join-Path $installDir 'router-launcher.exe'
$statusLog = Join-Path $installDir 'service.jsonl'
$trialDir = Join-Path $installDir 'trial'
$trialAuth = Join-Path $trialDir 'auth.json'
$trialConfig = Join-Path $trialDir 'config.toml'
$trialCwd = Join-Path $trialDir 'work'
$checkOptionsPath = Join-Path $installDir 'check-options.json'
$verify = Join-Path $PSScriptRoot 'check-codex.mjs'
$registered = $false
$published = $false
$hasConfig = Test-Path -LiteralPath $configPath -PathType Leaf
$previousText = if ($hasConfig) { [IO.File]::ReadAllText($configPath) } else { '' }

function Write-Json($Path, $Data) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Data -Depth 20) + [Environment]::NewLine, $utf8)
}

function Write-CodexConfig($Contents) {
    $null = [IO.Directory]::CreateDirectory($configDir)
    $tempConfig = Join-Path $configDir ('config-router-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($tempConfig, $Contents, $utf8)
    if (Test-Path -LiteralPath $configPath) {
        [IO.File]::Replace($tempConfig, $configPath, [NullString]::Value)
    } else {
        [IO.File]::Move($tempConfig, $configPath)
    }
}

function Test-Health {
    try {
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/health")
        $request.Proxy = $null
        $request.Timeout = 1500
        $response = $request.GetResponse()
        try {
            $reader = [IO.StreamReader]::new($response.GetResponseStream())
            $health = $reader.ReadToEnd() | ConvertFrom-Json
            return ($health.ok -eq $true -and $health.model -eq $providerModel)
        } finally {
            $response.Dispose()
        }
    } catch {
        return $false
    }
}

Write-Host "$version, $authMode sign-in, $codexDir"
$null = New-Item -ItemType Directory -Path $installDir
try {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($identity.User)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $identity.User, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
    ))
    Set-Acl -LiteralPath $installDir -AclObject $acl

    $null = New-Item -ItemType Directory -Path $trialDir, $trialCwd
    $options = @{ codexHome = $codexDir; cwd = $trialCwd; gptModel = $GptModel; providerModel = $providerModel }
    Write-Json $checkOptionsPath $options
    $preflight = & $node $verify preflight $codex $checkOptionsPath
    if ($LASTEXITCODE -ne 0) { throw 'Codex preflight failed.' }
    $options.gptModel = ($preflight | ConvertFrom-Json).gptModel
    $options.bundledFile = Join-Path $installDir 'openai-models.json'
    Write-Json $checkOptionsPath $options
    & $node $verify bundled $codex $checkOptionsPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the bundled OpenAI catalog.' }
    $bundled = [IO.File]::ReadAllText($options.bundledFile) | ConvertFrom-Json
    if ($bundled.models.slug -contains $providerModel) { throw 'The provider model ID is already in the OpenAI catalog.' }
    if ($authMode -eq 'api-key') {
        if ($bundled.models.slug -notcontains $options.gptModel) { throw 'Use an API GPT model included in the bundled catalog.' }
        $options.mergedFile = Join-Path $installDir 'merged-models.json'
        & $node (Join-Path $repo 'router\router.mjs') --merge-catalog $options.bundledFile $providerCatalogPath $options.mergedFile
        if ($LASTEXITCODE -ne 0) { throw 'Could not merge the API model catalog.' }
    }

    & $node --test (Join-Path $repo 'router\router.test.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'The router offline test failed.' }
    Copy-Item -LiteralPath (Join-Path $repo 'router\router.mjs') -Destination $nodeRouter
    $providerCatalogCopy = Join-Path $installDir 'provider-model.json'
    Copy-Item -LiteralPath $providerCatalogPath -Destination $providerCatalogCopy

    try {
        if ($ProviderKeyFile) {
            $token = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ProviderKeyFile).Path).Trim()
        } else {
            if (-not $PiAuthFile) {
                $piDir = if ($env:PI_CODING_AGENT_DIR) { $env:PI_CODING_AGENT_DIR }
                    elseif ($env:ORCA_PI_SOURCE_AGENT_DIR) { $env:ORCA_PI_SOURCE_AGENT_DIR }
                    else { Join-Path $env:USERPROFILE '.pi\agent' }
                $PiAuthFile = Join-Path $piDir 'auth.json'
            }
            $credential = ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $PiAuthFile).Path) | ConvertFrom-Json).'zai-coding-cn'
            if ($credential.type -eq 'api_key') { $token = [string] $credential.key }
        }
    } catch {
        throw 'Could not read the provider credential from the selected file.'
    }
    if ($token -cnotmatch '^[\x21-\x7e]{1,8192}$') { throw 'The source needs one saved provider API key.' }
    [IO.File]::WriteAllText($keyPath, $token, $utf8)
    $token = $null
    $credential = $null

    $random = [byte[]]::new(24)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $pathPrefix = '/' + [Convert]::ToBase64String($random).Replace('+', '-').Replace('/', '_')
    $routerConfig = @{
        port = $Port; pathPrefix = $pathPrefix; openaiAuth = $authMode
        providerBase = $upstream.AbsoluteUri; providerKeyFile = $keyPath
        providerCatalogFile = $providerCatalogCopy; fallbackCatalogFile = $options.bundledFile; logFile = $statusLog
    }
    $proxyEnv = @{}
    foreach ($name in 'HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY') {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($value) { $proxyEnv[$name] = $value }
    }
    if ($proxyEnv.Count) { $routerConfig.proxyEnv = $proxyEnv }
    Write-Json $routerConfigPath $routerConfig

    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe "/out:$launcher" (Join-Path $PSScriptRoot 'windows-router-launcher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the Windows model router launcher.' }
    $action = New-ScheduledTaskAction -Execute $launcher -WorkingDirectory $installDir -Argument ('"{0}"' -f $node)
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $recoveryTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) -RepetitionInterval (New-TimeSpan -Minutes 3)
    $taskPolicy = @{
        AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true
        ExecutionTimeLimit = [TimeSpan]::Zero; RestartCount = 3; RestartInterval = New-TimeSpan -Minutes 1
        MultipleInstances = 'IgnoreNew'
    }
    $taskSettings = New-ScheduledTaskSettingsSet @taskPolicy
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger, $recoveryTrigger) -Principal $principal -Settings $taskSettings
    $registered = $true
    Start-ScheduledTask -TaskName $taskName
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (Test-Health) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Health) -or -not (Test-Path -LiteralPath $statusLog)) { throw "The task '$taskName' did not start the router." }

    $routingLines = @('# Codex model router', "openai_base_url = 'http://127.0.0.1:$Port$pathPrefix/v1'")
    if ($options.mergedFile) { $routingLines += 'model_catalog_json = ' + (ConvertTo-Json -InputObject $options.mergedFile -Compress) }
    $routingBlock = ($routingLines -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine
    $updatedConfig = $routingBlock + $previousText

    $options.codexHome = $trialDir
    $options.routerFile = $routerConfigPath
    Write-Json $checkOptionsPath $options
    try {
        [IO.File]::WriteAllBytes($trialAuth, [IO.File]::ReadAllBytes($authFile))
        & $node $verify trial $codex $checkOptionsPath
        if ($LASTEXITCODE -ne 0) { throw 'The isolated same-thread model trial failed.' }
        if ($usesOrcaConfigMirror) {
            # Orca copies the source on its next launch. Check that configuration with the selected account here.
            [IO.File]::WriteAllText($trialConfig, $updatedConfig, $utf8)
            & $node $verify catalog $codex $checkOptionsPath
            if ($LASTEXITCODE -ne 0) { throw 'The proposed Orca source config did not expose both model entries.' }
        }
    } finally {
        if (Test-Path -LiteralPath $trialAuth) { Remove-Item -LiteralPath $trialAuth -Force }
        if (Test-Path -LiteralPath $trialConfig) { Remove-Item -LiteralPath $trialConfig -Force }
    }
    $routes = Get-Content -LiteralPath $statusLog | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.path -eq '/responses' -and $_.status -eq 200 } | ForEach-Object route
    if (($routes -join ',') -notmatch 'openai,(third-party,)+openai') { throw 'Router status did not confirm the three upstream routes.' }

    if ($hasConfig -ne (Test-Path -LiteralPath $configPath -PathType Leaf) -or
        ($hasConfig -and [IO.File]::ReadAllText($configPath) -cne $previousText)) {
        throw 'Codex configuration changed during testing. Retry with the current configuration.'
    }
    [IO.File]::WriteAllText((Join-Path $installDir 'codex-routing.toml'), $routingBlock, $utf8)
    if ($hasConfig) {
        [IO.File]::WriteAllBytes((Join-Path $installDir 'config.before.toml'), [IO.File]::ReadAllBytes($configPath))
    }
    Write-CodexConfig $updatedConfig
    $published = $true

    $options.codexHome = $codexDir
    Write-Json $checkOptionsPath $options
    if ($usesOrcaConfigMirror) {
        Write-Host "Installed '$taskName'. Open a new Codex session from Orca to sync $configPath."
    } else {
        & $node $verify catalog $codex $checkOptionsPath
        if ($LASTEXITCODE -ne 0) { throw 'The installed configuration did not expose both model entries.' }
        Write-Host "Installed '$taskName'. Open a fresh Codex session and select $providerModel in /model."
    }
} catch {
    if ($published) {
        $currentText = [IO.File]::ReadAllText($configPath)
        if ($currentText.StartsWith($routingBlock, [StringComparison]::Ordinal)) {
            $remainder = $currentText.Substring($routingBlock.Length)
            if ($remainder -or $hasConfig) { Write-CodexConfig $remainder }
            else { Remove-Item -LiteralPath $configPath }
        } else {
            throw "Config changed after installation. Review the routing block before stopping '$taskName'."
        }
    }
    if ($registered) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    if (Test-Path -LiteralPath $keyPath) { Remove-Item -LiteralPath $keyPath -Force }
    $failureDir = $installDir + '.failed-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $resolvedInstall = (Resolve-Path -LiteralPath $installDir).Path
    if ($resolvedInstall -eq $installDir -and [IO.Path]::GetDirectoryName($failureDir) -eq $codexDir) {
        Move-Item -LiteralPath $resolvedInstall -Destination $failureDir
        Write-Warning "Setup diagnostics are in $failureDir."
    }
    throw
}
