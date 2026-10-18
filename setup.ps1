<#
.SYNOPSIS
    Personal setup for AI Momentum tools in Claude Code on Windows. No admin rights needed.

.DESCRIPTION
    Each person runs this once, in an ordinary PowerShell window (not as administrator):

        irm https://raw.githubusercontent.com/AI-Momentum-Guild/tools/main/setup.ps1 | iex

    In order, it:
      1. Checks Git, Node.js and the GitHub CLI. IT normally installs these machine-wide
         (install-prerequisites.ps1); any that are missing are installed for this user with winget.
      2. Installs Claude Code with Anthropic's own installer (https://claude.ai/install.ps1),
         for this user only. Skipped if Claude Code is already installed.
      3. Signs the GitHub CLI in to GitHub (a browser sign-in) and, unless Git already has a
         credential helper for github.com, lets Git use it, so Claude Code can read private repositories.
      4. Adds each AI Momentum plugin marketplace this GitHub account can reach, plus the team
         toolshed if one is given, installs their plugins, and turns automatic updates on for them.

    It is safe to run again: every step that is already done is skipped.
    It changes nothing else, and sends nothing to AI Momentum.

.PARAMETER Toolshed
    The team toolshed repository, as <github-org>/<repository>. Optional.

.PARAMETER WhatIf
    Dry run: reports what would be done and changes nothing.

.EXAMPLE
    irm https://raw.githubusercontent.com/AI-Momentum-Guild/tools/main/setup.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/AI-Momentum-Guild/tools/main/setup.ps1))) -Toolshed example-aviation/example-aviation-toolshed -WhatIf

.NOTES
    Built under MSD #53757 (D19, D24, D25). Exit codes: 0 done; 1 a step failed (the line says why).
    Works on Windows PowerShell 5.1 and PowerShell 7, on x64 and ARM64.
    Log: %LOCALAPPDATA%\AI-Dev-Foundations\Logs
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console output is the report the person reads and the transcript logs; Write-Output would mix text into function return values.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Only in the documented one-liner, not in the script.')]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Toolshed
)

# Under irm | iex this runs in the person's own session, so their error preference is put back at the end.
$script:CallerErrorAction = $ErrorActionPreference
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SetupVersion = '0.1.0'
$script:SignedIn = $false
$script:ClaudeInstaller = 'https://claude.ai/install.ps1'

$script:Tools = @(
    [pscustomobject]@{ Command = 'git';  Name = 'Git';        WingetId = 'Git.Git' }
    [pscustomobject]@{ Command = 'node'; Name = 'Node.js';    WingetId = 'OpenJS.NodeJS.LTS' }
    [pscustomobject]@{ Command = 'gh';   Name = 'GitHub CLI'; WingetId = 'GitHub.cli' }
)

# The AI Momentum marketplaces (MSD #53757 D14). Each is added only if this GitHub account can reach it.
$script:Marketplaces = @(
    [pscustomobject]@{ Repo = 'AI-Momentum-Guild/tools';     Name = 'ai-momentum';     Plugins = @() }
    [pscustomobject]@{ Repo = 'AI-Momentum-Guild/pro';       Name = 'ai-momentum-pro'; Plugins = @() }
    [pscustomobject]@{ Repo = 'AI-Momentum-Guild/dev-tools'; Name = 'ai-momentum-dev'; Plugins = @('ai-dev-foundations') }
)

function Invoke-Native {
    <#
        Runs a program. Returns its exit code, Stdout (for parsing) and Output (stdout and stderr together,
        for messages). Every external call goes through here, so tests can stand in for it.
    #>
    param([Parameter(Mandatory)] [string]$Command, [string[]]$Arguments = @())
    $cmd = Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return [pscustomobject]@{ ExitCode = 127; Stdout = ''; Output = "$Command is not installed" } }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = @(); $all = @()
        # Windows PowerShell 5.1 wraps each stderr line in an error record; keep only its text.
        foreach ($line in (& $cmd.Source @Arguments 2>&1)) {
            if ($line -is [Management.Automation.ErrorRecord]) { $all += $line.ToString() }
            else { $stdout += "$line"; $all += "$line" }
        }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Stdout = ($stdout -join "`n").Trim(); Output = ($all -join "`n").Trim() }
    }
    finally { $ErrorActionPreference = $previous }
}

function Invoke-Interactive {
    <# Runs a program that talks to the person (a browser sign-in), with its output on screen. #>
    param([Parameter(Mandatory)] [string]$Command, [string[]]$Arguments = @())
    & $Command @Arguments | Out-Host
    return $LASTEXITCODE
}

function Test-Tool {
    param([Parameter(Mandatory)] [string]$Command)
    return [bool](Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue)
}

function Write-Step {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [string]$Status)
    Write-Host ('{0,-22} {1}' -f $Name, $Status)
}

function Import-SessionPath {
    # Installers add to the stored PATH; reload it, plus Claude Code's per-user folder, for this window.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $claudeBin = Join-Path $HOME '.local\bin'
    $env:PATH = (@($machine, $user, $claudeBin, $env:PATH) | Where-Object { $_ }) -join ';'
}

function Install-MissingTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Tool)
    if (Test-Tool $Tool.Command) {
        Write-Step $Tool.Name 'present'
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess($Tool.Name, 'Install for this user with winget')) {
        Write-Step $Tool.Name 'missing; would be installed with winget'
        return $true
    }
    $run = Invoke-Native winget @('install', '--id', $Tool.WingetId, '--exact', '--source', 'winget', '--scope', 'user', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    Import-SessionPath
    if (Test-Tool $Tool.Command) {
        Write-Step $Tool.Name 'installed'
        return $true
    }
    $why = if ($run.ExitCode -eq 127) { 'winget is not available' } else { 'winget could not install it for this user' }
    Write-Step $Tool.Name "FAILED: $why. Ask IT to run install-prerequisites.ps1, then run this again"
    return $false
}

function Install-ClaudeCode {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param()
    if (Test-Tool 'claude') {
        Write-Step 'Claude Code' 'present'
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess('Claude Code', "Install for this user with Anthropic's installer")) {
        Write-Step 'Claude Code' "missing; would be installed from $script:ClaudeInstaller"
        return $true
    }
    & ([scriptblock]::Create((Invoke-RestMethod -Uri $script:ClaudeInstaller -UseBasicParsing))) | Out-Host
    Import-SessionPath
    if (Test-Tool 'claude') {
        Write-Step 'Claude Code' 'installed'
        return $true
    }
    Write-Step 'Claude Code' "FAILED: the installer ran but claude is not on PATH. Open a new PowerShell window and run this again"
    return $false
}

function Connect-GitHub {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param()
    $script:SignedIn = (Invoke-Native gh @('auth', 'status', '--hostname', 'github.com')).ExitCode -eq 0
    if ($script:SignedIn) {
        Write-Step 'GitHub sign-in' 'already signed in'
    }
    elseif (-not $PSCmdlet.ShouldProcess('GitHub CLI', 'Sign in to github.com in the browser')) {
        Write-Step 'GitHub sign-in' 'would open a browser sign-in'
    }
    else {
        Write-Host 'Signing the GitHub CLI in to GitHub. Follow the prompts; a browser window opens.'
        $code = Invoke-Interactive gh @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web')
        if ($code -ne 0) {
            Write-Step 'GitHub sign-in' 'FAILED: run gh auth login yourself, then run this again'
            return $false
        }
        Write-Step 'GitHub sign-in' 'signed in'
        $script:SignedIn = $true
    }

    # D25(4): never replace a credential helper Git already uses for github.com, set at any level,
    # including Git for Windows' own Git Credential Manager. Git then asks that helper to sign in.
    $existing = Invoke-Native git @('config', '--get-urlmatch', 'credential.helper', 'https://github.com')
    if ($existing.ExitCode -eq 0 -and $existing.Stdout) {
        Write-Step 'Git and GitHub' "Git already signs in to GitHub with '$($existing.Stdout)'; left unchanged"
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess('Git', 'Use the GitHub CLI as the credential helper for github.com')) {
        Write-Step 'Git and GitHub' 'would let Git use the GitHub CLI sign-in'
        return $true
    }
    $setup = Invoke-Native gh @('auth', 'setup-git', '--hostname', 'github.com')
    if ($setup.ExitCode -ne 0) {
        Write-Step 'Git and GitHub' "FAILED: gh auth setup-git: $($setup.Output)"
        return $false
    }
    Write-Step 'Git and GitHub' 'Git uses the GitHub CLI sign-in'
    return $true
}

function Get-InstalledMarketplace {
    $res = Invoke-Native claude @('plugin', 'marketplace', 'list', '--json')
    if ($res.ExitCode -ne 0 -or -not $res.Stdout) { return @() }
    try { return @(($res.Stdout | ConvertFrom-Json) | ForEach-Object { $_.name }) }
    catch { throw "could not read the list of Claude Code marketplaces (claude plugin marketplace list --json): $($_.Exception.Message)" }
}

function Get-InstalledPlugin {
    $res = Invoke-Native claude @('plugin', 'list', '--json')
    if ($res.ExitCode -ne 0 -or -not $res.Stdout) { return @() }
    try { return @(($res.Stdout | ConvertFrom-Json) | ForEach-Object { $_.id }) }
    catch { throw "could not read the list of Claude Code plugins (claude plugin list --json): $($_.Exception.Message)" }
}

function Get-ToolshedMarketplace {
    <# The toolshed's marketplace name and its one plugin (D12), read from its marketplace.json on GitHub. #>
    param([Parameter(Mandatory)] [string]$Repo)
    $res = Invoke-Native gh @('api', "repos/$Repo/contents/.claude-plugin/marketplace.json", '-H', 'Accept: application/vnd.github.raw+json')
    if ($res.ExitCode -ne 0) { throw "cannot read $Repo. Check the name, and that your GitHub account has been given access" }
    try { $manifest = $res.Stdout | ConvertFrom-Json }
    catch { throw "$Repo does not look like a team toolshed: its .claude-plugin/marketplace.json could not be read" }
    $plugins = @($manifest.plugins | ForEach-Object { $_.name })
    if ($plugins.Count -ne 1) { throw "$Repo does not look like a team toolshed: it should hold exactly one plugin, but lists $($plugins.Count)" }
    return [pscustomobject]@{ Repo = $Repo; Name = $manifest.name; Plugins = $plugins }
}

# Returns ok, skipped (no access, and not required) or failed.
function Add-Marketplace {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Market, [string[]]$Installed = @(), [string[]]$InstalledPlugins = @(), [switch]$Required)
    $label = $Market.Name
    if ((Invoke-Native gh @('repo', 'view', $Market.Repo, '--json', 'name')).ExitCode -ne 0) {
        if ($Required) {
            Write-Step $label "FAILED: cannot reach $($Market.Repo). Check the name, and that your GitHub account has been given access"
            return 'failed'
        }
        Write-Step $label 'skipped: your GitHub account does not have access'
        return 'skipped'
    }
    if ($Installed -contains $Market.Name) {
        Write-Step $label 'marketplace already added'
    }
    elseif (-not $PSCmdlet.ShouldProcess($Market.Repo, 'Add plugin marketplace')) {
        Write-Step $label "would add marketplace $($Market.Repo)"
    }
    else {
        $add = Invoke-Native claude @('plugin', 'marketplace', 'add', $Market.Repo)
        if ($add.ExitCode -ne 0) {
            Write-Step $label "FAILED: claude plugin marketplace add: $($add.Output)"
            return 'failed'
        }
        Write-Step $label 'marketplace added'
    }
    foreach ($plugin in $Market.Plugins) {
        $id = "$plugin@$($Market.Name)"
        if ($InstalledPlugins -contains $id) {
            Write-Step $plugin 'already installed'
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($id, 'Install plugin')) {
            Write-Step $plugin 'would be installed'
            continue
        }
        $install = Invoke-Native claude @('plugin', 'install', $id)
        if ($install.ExitCode -ne 0) {
            Write-Step $plugin "FAILED: claude plugin install: $($install.Output)"
            return 'failed'
        }
        Write-Step $plugin 'installed'
    }
    return 'ok'
}

function Set-MarketplaceAutoUpdate {
    <#
        Turns automatic updates on for the given marketplaces, through extraKnownMarketplaces in the
        person's Claude Code settings. Every other setting in the file is kept.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Markets, [string]$SettingsPath = (Join-Path $HOME '.claude\settings.json'))
    if (-not $Markets.Count) { return $true }
    $settings = [pscustomobject]@{}
    if (Test-Path $SettingsPath) {
        $text = [IO.File]::ReadAllText($SettingsPath)
        if ($text.Trim()) {
            try { $settings = $text | ConvertFrom-Json }
            catch {
                Write-Step 'Automatic updates' "FAILED: $SettingsPath is not valid JSON, so it was left alone. Fix it and run this again"
                return $false
            }
        }
    }
    if (-not $settings.PSObject.Properties['extraKnownMarketplaces']) {
        $settings | Add-Member -NotePropertyName extraKnownMarketplaces -NotePropertyValue ([pscustomobject]@{})
    }
    $known = $settings.extraKnownMarketplaces
    $changed = @()
    foreach ($market in $Markets) {
        $entry = $known.PSObject.Properties[$market.Name]
        if ($entry -and $entry.Value.PSObject.Properties['autoUpdate'] -and $entry.Value.autoUpdate -eq $true) { continue }
        if ($entry) {
            # Someone (perhaps IT) declared it already: keep their source, pin or mirror, and only switch updates on.
            $entry.Value | Add-Member -NotePropertyName autoUpdate -NotePropertyValue $true -Force
        }
        else {
            $value = [pscustomobject]@{ source = [pscustomobject]@{ source = 'github'; repo = $market.Repo }; autoUpdate = $true }
            $known | Add-Member -NotePropertyName $market.Name -NotePropertyValue $value
        }
        $changed += $market.Name
    }
    if (-not $changed.Count) {
        Write-Step 'Automatic updates' 'already on'
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess($SettingsPath, "Turn on automatic updates for $($changed -join ', ')")) {
        Write-Step 'Automatic updates' "would be turned on for $($changed -join ', ')"
        return $true
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath) | Out-Null
    # UTF-8 without a byte order mark: Windows PowerShell 5.1's Set-Content would add one.
    [IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 64), (New-Object Text.UTF8Encoding($false)))
    Write-Step 'Automatic updates' "on for $($changed -join ', ')"
    return $true
}

function Invoke-Setup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([int])]
    param([string]$Toolshed)
    Write-Host "AI Momentum tools: personal setup $script:SetupVersion"
    if ($Toolshed -and $Toolshed -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]+$') {
        Write-Host "Toolshed '$Toolshed' should look like <github-org>/<repository>. Nothing was changed."
        return 1
    }
    Import-SessionPath

    foreach ($tool in $script:Tools) {
        if (-not (Install-MissingTool -Tool $tool)) { return 1 }
    }
    if (-not (Install-ClaudeCode)) { return 1 }
    if (-not (Test-Tool 'gh') -or -not (Test-Tool 'claude')) {
        if (-not $WhatIfPreference) {
            Write-Host 'FAILED: the GitHub CLI or Claude Code is still not available. Open a new PowerShell window and run this again.'
            return 1
        }
        Write-Host ''
        Write-Host 'Dry run: the remaining steps need the GitHub CLI and Claude Code installed.'
        return 0
    }
    if (-not (Connect-GitHub)) { return 1 }
    if ($WhatIfPreference -and -not $script:SignedIn) {
        Write-Host ''
        Write-Host 'Dry run: after the GitHub sign-in, it would add the marketplaces your account can reach, install their plugins and turn automatic updates on.'
        return 0
    }

    $markets = @($script:Marketplaces)
    if ($Toolshed) {
        try { $shed = Get-ToolshedMarketplace -Repo $Toolshed }
        catch {
            Write-Step 'Team toolshed' "FAILED: $($_.Exception.Message)"
            return 1
        }
        $markets += $shed
    }
    $installed = Get-InstalledMarketplace
    $plugins = Get-InstalledPlugin
    $reached = @()
    foreach ($market in $markets) {
        $required = ($Toolshed -and $market.Repo -eq $Toolshed)
        $result = Add-Marketplace -Market $market -Installed $installed -InstalledPlugins $plugins -Required:$required
        if ($result -eq 'failed') { return 1 }
        if ($result -eq 'ok') { $reached += $market }
    }
    if (-not (Set-MarketplaceAutoUpdate -Markets $reached)) { return 1 }

    Write-Host ''
    if ($WhatIfPreference) {
        Write-Host 'Dry run finished: nothing was changed.'
    }
    else {
        Write-Host 'Done. Open Claude Code (type claude in a new PowerShell window) and say: "update the team toolshed".'
        Write-Host 'When you no longer need GitHub access from this computer, run: gh auth logout'
    }
    return 0
}

# Dot-sourcing (as the tests do) loads the functions without running anything.
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    $logStarted = $false
    try {
        if (-not $WhatIfPreference -and $env:LOCALAPPDATA) {
            $logDirectory = Join-Path $env:LOCALAPPDATA 'AI-Dev-Foundations\Logs'
            New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
            $log = Join-Path $logDirectory ('setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
            Start-Transcript -Path $log | Out-Null
            $logStarted = $true
        }
        $exitCode = Invoke-Setup -Toolshed $Toolshed
    }
    catch {
        Write-Host "Stopped: $($_.Exception.Message)"
        $exitCode = 1
    }
    finally {
        if ($logStarted) { Stop-Transcript | Out-Null; Write-Host "Log: $log" }
    }
    # Run with irm | iex, this is the person's own PowerShell window: exit would close it,
    # and strict mode and 'Stop' would otherwise stay on in it after the script ends.
    if ($PSCommandPath) { exit $exitCode }
    Set-StrictMode -Off
    $ErrorActionPreference = $script:CallerErrorAction
    $global:LASTEXITCODE = $exitCode
}
