<#
.SYNOPSIS
  Runs a controlled two-phase registry connection failure and recovery demo.

.DESCRIPTION
  Break:
    - changes the dev Foundry connection to an invalid JFrog OIDC provider;
    - commits and pushes the change to main;
    - waits for foundation-apply;
    - creates an empty agent-repo commit to force a unique image tag;
    - runs the agent workflow and requires an exchange_failed error.

  Fix:
    - restores the original provider name;
    - commits and pushes the correction to main;
    - waits for foundation-apply;
    - redeploys the exact image tag that failed;
    - requires successful activation and smoke-test evidence.

  Break exits after saving a checkpoint under ~/.foundry-platform. Run Fix only
  after the presenter gives approval in chat.

.EXAMPLE
  ./scripts/demo-registry-connection.ps1 -Phase Break

.EXAMPLE
  ./scripts/demo-registry-connection.ps1 -Phase Fix
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Break', 'Fix')]
    [string]$Phase,

    [string]$EnvName = 'dev',
    [string]$FoundationRepo = 'clekkas/jfrog-oidc-foundry',
    [string]$AgentRepo = 'clekkas/byor-agent',
    [string]$ValidProviderName = 'oidc-byor',
    [string]$InvalidProviderName = 'oidc-byor-demo-invalid',
    [string]$FoundationRunnerVm = 'byor-ci-runner-01',
    [string]$AgentRunnerVm = 'byor-ci-agent-runner-01',
    [switch]$KeepRunnersRunning
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_common.ps1"

$cfg = Get-FoundationConfig -Root $root -EnvName $EnvName
$stateDir = Join-Path $env:USERPROFILE '.foundry-platform'
$stateFile = Join-Path $stateDir "registry-connection-demo-$EnvName.json"
$tfvarsRelativePath = "infra/registry-connection/environments/$EnvName.tfvars"

function Invoke-Captured {
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $lines = & $File @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($lines | Out-String).TrimEnd()
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ($text) { Write-Host $text }
        throw "$File $($Arguments -join ' ') failed with exit code $exitCode"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $text
    }
}

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found."
    }
}

function Assert-MainReady {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $branch = (Invoke-Captured git @('-C', $RepositoryRoot, 'branch', '--show-current')).Output.Trim()
    if ($branch -ne 'main') { throw "Expected branch main, found '$branch'." }

    $tracked = (Invoke-Captured git @('-C', $RepositoryRoot, 'status', '--porcelain', '--untracked-files=no')).Output
    if ($tracked) { throw "Tracked worktree changes must be committed or reverted before the demo:`n$tracked" }

    Invoke-Captured git @('-C', $RepositoryRoot, 'fetch', 'origin', 'main') | Out-Null
    $counts = (Invoke-Captured git @('-C', $RepositoryRoot, 'rev-list', '--left-right', '--count', 'origin/main...main')).Output -split '\s+'
    if ($counts.Count -ne 2 -or $counts[0] -ne '0' -or $counts[1] -ne '0') {
        throw "Local main must exactly match origin/main (behind=$($counts[0]), ahead=$($counts[1]))."
    }
}

function Set-OidcProviderName {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    $content = [IO.File]::ReadAllText($Path)
    $pattern = "(?m)^(\s*oidc_provider_name\s*=\s*)`"$([regex]::Escape($From))`"(\s*(?:#.*)?)$"
    $regex = [regex]::new($pattern)
    $matches = $regex.Matches($content)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one oidc_provider_name = `"$From`" in $Path; found $($matches.Count)."
    }

    $updated = $regex.Replace(
        $content,
        { param($match) "$($match.Groups[1].Value)`"$To`"$($match.Groups[2].Value)" },
        1
    )
    [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false))
}

function Commit-And-Push {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body
    )

    Invoke-Captured git @('-C', $RepositoryRoot, 'add', '--', $Path) | Out-Null
    Invoke-Captured git @(
        '-C', $RepositoryRoot, 'commit',
        '-m', $Subject,
        '-m', $Body,
        '-m', 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>'
    ) | Out-Null
    Invoke-Captured git @('-C', $RepositoryRoot, 'push', 'origin', 'main') | Out-Null
    (Invoke-Captured git @('-C', $RepositoryRoot, 'rev-parse', 'HEAD')).Output.Trim()
}

function Wait-RunnerOnline {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$RunnerName
    )

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $status = (Invoke-Captured gh @(
            'api', "repos/$Repository/actions/runners",
            '--jq', ".runners[] | select(.name==`"$RunnerName`") | .status"
        )).Output.Trim()
        if ($status -eq 'online') { return }
        Start-Sleep -Seconds 5
    }
    throw "Runner '$RunnerName' did not come online within five minutes."
}

function Start-DemoRunner {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$VmName
    )

    $status = (Invoke-Captured gh @(
        'api', "repos/$Repository/actions/runners",
        '--jq', ".runners[] | select(.name==`"$VmName`") | .status"
    )).Output.Trim()
    if ($status -eq 'online') {
        Write-Host "==> Runner '$VmName' is already online"
        return $false
    }

    Write-Host "==> Starting runner VM '$VmName'"
    Invoke-Captured az @(
        'vm', 'start',
        '--subscription', $cfg.SubscriptionId,
        '--resource-group', $cfg.ResourceGroup,
        '--name', $VmName,
        '--no-wait'
    ) | Out-Null
    Wait-RunnerOnline -Repository $Repository -RunnerName $VmName
    return $true
}

function Stop-DemoRunner {
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][bool]$StartedByScript
    )

    if (-not $StartedByScript -or $KeepRunnersRunning) { return }
    Write-Host "==> Deallocating runner VM '$VmName'"
    Invoke-Captured az @(
        'vm', 'deallocate',
        '--subscription', $cfg.SubscriptionId,
        '--resource-group', $cfg.ResourceGroup,
        '--name', $VmName
    ) | Out-Null
}

function Find-WorkflowRun {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Workflow,
        [Parameter(Mandatory)][string]$Commit,
        [string]$Event
    )

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $arguments = @(
            'run', 'list',
            '--repo', $Repository,
            '--workflow', $Workflow,
            '--commit', $Commit,
            '--limit', '5',
            '--json', 'databaseId'
        )
        if ($Event) { $arguments += @('--event', $Event) }
        $runs = (Invoke-Captured gh $arguments).Output | ConvertFrom-Json
        if ($runs.Count -gt 0) { return [string]$runs[0].databaseId }
        Start-Sleep -Seconds 2
    }
    throw "No $Workflow run appeared for commit $Commit in $Repository."
}

function Wait-WorkflowRun {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$RunId,
        [switch]$ExpectFailure
    )

    & gh run watch $RunId --repo $Repository --exit-status
    $exitCode = $LASTEXITCODE
    if ($ExpectFailure) {
        if ($exitCode -eq 0) { throw "Run $RunId unexpectedly succeeded; the negative test is invalid." }
    } elseif ($exitCode -ne 0) {
        throw "Run $RunId failed with exit code $exitCode."
    }
}

function Start-WorkflowRun {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-Captured gh (@('workflow', 'run') + $Arguments + @('--repo', $Repository))
    if ($result.Output -notmatch '/actions/runs/(\d+)') {
        throw "GitHub did not return a workflow run URL:`n$($result.Output)"
    }
    $Matches[1]
}

function Save-DemoState {
    param([Parameter(Mandatory)]$State)
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding utf8
}

function New-AgentDemoCommit {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "registry-demo-$([guid]::NewGuid())"
    try {
        Invoke-Captured git @('clone', '--quiet', "https://github.com/$AgentRepo.git", $tempRoot) | Out-Null
        Invoke-Captured git @('-C', $tempRoot, 'config', 'user.name', 'Registry Connection Demo') | Out-Null
        Invoke-Captured git @('-C', $tempRoot, 'config', 'user.email', '223556219+Copilot@users.noreply.github.com') | Out-Null
        Invoke-Captured git @(
            '-C', $tempRoot, 'commit', '--allow-empty',
            '-m', 'Trigger registry connection demo',
            '-m', 'Creates a unique image tag without changing application code.',
            '-m', 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>'
        ) | Out-Null
        Invoke-Captured git @('-C', $tempRoot, 'push', 'origin', 'main') | Out-Null
        return (Invoke-Captured git @('-C', $tempRoot, 'rev-parse', 'HEAD')).Output.Trim()
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

foreach ($command in 'az', 'gh', 'git') { Assert-Command $command }
Invoke-Captured gh @('auth', 'status') | Out-Null
Invoke-Captured az @('account', 'set', '--subscription', $cfg.SubscriptionId) | Out-Null
Assert-MainReady -RepositoryRoot $root

$foundationRunnerStarted = $false
$agentRunnerStarted = $false

if ($Phase -eq 'Break') {
    if (Test-Path $stateFile) {
        throw "An unfinished demo checkpoint already exists at $stateFile. Run -Phase Fix before starting another demo."
    }
    if ($ValidProviderName -eq $InvalidProviderName) {
        throw 'ValidProviderName and InvalidProviderName must differ.'
    }

    $state = [ordered]@{
        environment          = $EnvName
        foundationRepository = $FoundationRepo
        agentRepository      = $AgentRepo
        validProviderName    = $ValidProviderName
        invalidProviderName  = $InvalidProviderName
        status               = 'starting-break'
        startedAtUtc         = [DateTime]::UtcNow.ToString('o')
    }
    Save-DemoState $state

    try {
        $foundationRunnerStarted = Start-DemoRunner -Repository $FoundationRepo -VmName $FoundationRunnerVm

        Write-Host "==> Breaking the connection: $ValidProviderName -> $InvalidProviderName"
        Set-OidcProviderName -Path $cfg.TfvarsPath -From $ValidProviderName -To $InvalidProviderName
        $foundationCommit = Commit-And-Push `
            -RepositoryRoot $root `
            -Path $tfvarsRelativePath `
            -Subject 'Demo broken registry OIDC provider' `
            -Body 'Intentionally use an invalid provider name to demonstrate registry authentication failure.'
        $state.foundationBreakCommit = $foundationCommit
        $state.status = 'waiting-for-broken-foundation'
        Save-DemoState $state

        $foundationRun = Find-WorkflowRun `
            -Repository $FoundationRepo `
            -Workflow 'foundation-apply.yml' `
            -Commit $foundationCommit
        Wait-WorkflowRun -Repository $FoundationRepo -RunId $foundationRun
        $state.foundationBreakRun = $foundationRun
        $state.status = 'connection-broken'
        Save-DemoState $state

        $agentRunnerStarted = Start-DemoRunner -Repository $AgentRepo -VmName $AgentRunnerVm
        Write-Host '==> Creating a unique agent image tag without changing application code'
        $agentCommit = New-AgentDemoCommit
        $imageTag = "sha-$($agentCommit.Substring(0, 7))"
        $state.agentCommit = $agentCommit
        $state.imageTag = $imageTag
        Save-DemoState $state

        Write-Host "==> Deploying $imageTag; exchange_failed is expected"
        $agentRun = Start-WorkflowRun `
            -Repository $AgentRepo `
            -Arguments @(
                'deploy-agent.yml',
                '--ref', 'main'
            )
        Wait-WorkflowRun -Repository $AgentRepo -RunId $agentRun -ExpectFailure

        $failureLogs = (Invoke-Captured gh @(
            'run', 'view', $agentRun,
            '--repo', $AgentRepo,
            '--log-failed'
        )).Output
        if ($failureLogs -notmatch 'exchange_failed' -or $failureLogs -notmatch "oidc integration doesn't exist") {
            throw "Agent run $agentRun failed, but not with the required registry OIDC exchange evidence."
        }

        $state.agentFailureRun = $agentRun
        $state.status = 'failure-proven'
        Save-DemoState $state

        Write-Host @"

BREAK PHASE COMPLETE
  Invalid provider : $InvalidProviderName
  Foundation run   : https://github.com/$FoundationRepo/actions/runs/$foundationRun
  Failed agent run : https://github.com/$AgentRepo/actions/runs/$agentRun
  Failed image tag : $imageTag
  Evidence         : exchange_failed / oidc integration doesn't exist

The connection is intentionally broken. Return to chat and wait for approval.
After approval, run:
  ./scripts/demo-registry-connection.ps1 -Phase Fix
"@
    } finally {
        Stop-DemoRunner -VmName $AgentRunnerVm -StartedByScript $agentRunnerStarted
        Stop-DemoRunner -VmName $FoundationRunnerVm -StartedByScript $foundationRunnerStarted
    }
    exit 0
}

if (-not (Test-Path $stateFile)) {
    throw "No demo checkpoint exists at $stateFile. Run -Phase Break first."
}

$state = Get-Content $stateFile -Raw | ConvertFrom-Json
if ($state.status -ne 'failure-proven') {
    throw "The checkpoint status is '$($state.status)', not 'failure-proven'. Refusing to run recovery without a proven failure."
}
if ($state.foundationRepository -ne $FoundationRepo -or $state.agentRepository -ne $AgentRepo) {
    throw 'The checkpoint repositories do not match the requested repositories.'
}

try {
    $foundationRunnerStarted = Start-DemoRunner -Repository $FoundationRepo -VmName $FoundationRunnerVm

    Write-Host "==> Restoring the connection: $($state.invalidProviderName) -> $($state.validProviderName)"
    Set-OidcProviderName `
        -Path $cfg.TfvarsPath `
        -From $state.invalidProviderName `
        -To $state.validProviderName
    $foundationCommit = Commit-And-Push `
        -RepositoryRoot $root `
        -Path $tfvarsRelativePath `
        -Subject 'Restore registry OIDC provider after demo' `
        -Body 'Reinstate the valid JFrog provider name after proving the controlled token-exchange failure.'

    $foundationRun = Find-WorkflowRun `
        -Repository $FoundationRepo `
        -Workflow 'foundation-apply.yml' `
        -Commit $foundationCommit
    Wait-WorkflowRun -Repository $FoundationRepo -RunId $foundationRun

    $agentRunnerStarted = Start-DemoRunner -Repository $AgentRepo -VmName $AgentRunnerVm
    Write-Host "==> Redeploying the exact failed image tag: $($state.imageTag)"
    $agentRun = Start-WorkflowRun `
        -Repository $AgentRepo `
        -Arguments @(
            'deploy-agent.yml',
            '--ref', 'main',
            '-f', "image_tag=$($state.imageTag)"
        )
    Wait-WorkflowRun -Repository $AgentRepo -RunId $agentRun

    $successLogs = (Invoke-Captured gh @(
        'run', 'view', $agentRun,
        '--repo', $AgentRepo,
        '--log'
    )).Output
    if ($successLogs -notmatch 'Agent version \d+ is active with the expected image' -or
        $successLogs -notmatch 'smoke test passed') {
        throw "Agent run $agentRun succeeded but required activation and smoke-test evidence was not found."
    }

    Remove-Item -LiteralPath $stateFile -Force
    Write-Host @"

FIX PHASE COMPLETE
  Valid provider         : $($state.validProviderName)
  Foundation recovery   : https://github.com/$FoundationRepo/actions/runs/$foundationRun
  Successful agent run  : https://github.com/$AgentRepo/actions/runs/$agentRun
  Redeployed image tag  : $($state.imageTag)
  Evidence              : new version active / smoke test passed

The registry connection is restored and the demo checkpoint was removed.
"@
} finally {
    Stop-DemoRunner -VmName $AgentRunnerVm -StartedByScript $agentRunnerStarted
    Stop-DemoRunner -VmName $FoundationRunnerVm -StartedByScript $foundationRunnerStarted
}
