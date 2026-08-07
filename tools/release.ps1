[CmdletBinding()]
param(
    [switch]$Bump
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[INFO] $Message"
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Command
    )

    Write-Info $Name
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Name 失败，退出码：$LASTEXITCODE"
    }
}

function Invoke-GitLines {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    [array]$output = @(& git @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "无法读取 Git 状态：$Description"
    }
    return $output
}

function Get-VersionFromText {
    param([Parameter(Mandatory)][string]$Text)

    $declarationMatches = [regex]::Matches(
        $Text,
        '(?m)^[\t ]*(?:(?:export|readonly|local)[\t ]+|(?:declare|typeset)(?:[\t ]+-[^\t \r\n]+)*[\t ]+)?VPSBOX_VERSION[\t ]*='
    )
    $canonicalMatches = [regex]::Matches(
        $Text,
        '(?m)^VPSBOX_VERSION="(v[0-9]+\.[0-9]+\.[0-9]+)"\r?$'
    )
    if ($declarationMatches.Count -ne 1 -or $canonicalMatches.Count -ne 1) {
        throw 'vpsbox.sh 必须且只能包含一个格式正确的 VPSBOX_VERSION。'
    }
    return $canonicalMatches[0].Groups[1].Value
}

function Get-ReadmeVersionFromText {
    param([Parameter(Mandatory)][string]$Text)

    $summaryMatches = [regex]::Matches(
        $Text,
        '(?m)^当前版本：`(v[0-9]+\.[0-9]+\.[0-9]+)`\r?$'
    )
    $menuMatches = [regex]::Matches(
        $Text,
        '(?m)^ 版本：(v[0-9]+\.[0-9]+\.[0-9]+)\r?$'
    )
    if ($summaryMatches.Count -ne 1 -or $menuMatches.Count -ne 1) {
        throw 'README.md 必须且只能包含一个规范的当前版本和一个主菜单版本。'
    }

    $summaryVersion = $summaryMatches[0].Groups[1].Value
    $menuVersion = $menuMatches[0].Groups[1].Value
    if ($summaryVersion -cne $menuVersion) {
        throw "README.md 两处版本不一致：当前版本为 $summaryVersion，主菜单示例为 $menuVersion。"
    }
    return $summaryVersion
}

function Set-ReadmeVersionInText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Version
    )

    [void](Get-ReadmeVersionFromText -Text $Text)
    if ($Version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "README.md 目标版本号格式不正确：$Version"
    }

    $updated = [regex]::Replace(
        $Text,
        '(?m)^当前版本：`v[0-9]+\.[0-9]+\.[0-9]+`(\r?)$',
        ('当前版本：`{0}`$1' -f $Version)
    )
    return [regex]::Replace(
        $updated,
        '(?m)^ 版本：v[0-9]+\.[0-9]+\.[0-9]+(\r?)$',
        (' 版本：{0}$1' -f $Version)
    )
}

function Get-NextPatchVersion {
    param([Parameter(Mandatory)][string]$Version)

    if ($Version -notmatch '^v([0-9]+)\.([0-9]+)\.([0-9]+)$') {
        throw "版本号格式不正确：$Version"
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $patch = [int]$Matches[3]
    if ($patch -gt 99) {
        throw "补丁版本号必须在 0-99 范围内：$Version"
    }
    if ($patch -eq 99) {
        $minor += 1
        $patch = 0
    }
    else {
        $patch += 1
    }
    return 'v{0}.{1}.{2}' -f $major, $minor, $patch
}

function Get-HeadVersion {
    [array]$headLines = @(Invoke-GitLines `
            -Description 'HEAD 中的 vpsbox.sh' `
            -Arguments @('show', 'HEAD:vpsbox.sh'))
    return Get-VersionFromText -Text ($headLines -join "`n")
}

function Assert-RepositoryState {
    [array]$stagedPaths = @(Invoke-GitLines `
            -Description '已暂存文件列表' `
            -Arguments @('diff', '--cached', '--name-only', '--diff-filter=ACDMRTUXB'))
    [array]$unstagedPaths = @(Invoke-GitLines `
            -Description '未暂存文件列表' `
            -Arguments @('diff', '--name-only', '--diff-filter=ACDMRTUXB'))
    if ($stagedPaths.Count -gt 0 -and $unstagedPaths.Count -gt 0) {
        throw (
            '检测到已暂存和未暂存改动同时存在。' +
            '请先统一暂存全部改动，或取消暂存后重试。'
        )
    }

    [array]$conflicts = @(
        @(Invoke-GitLines `
                -Description '工作树冲突' `
                -Arguments @('diff', '--name-only', '--diff-filter=U')) +
        @(Invoke-GitLines `
                -Description '暂存区冲突' `
                -Arguments @('diff', '--cached', '--name-only', '--diff-filter=U'))
    )
    if ($conflicts.Count -gt 0) {
        throw "存在尚未解决的 Git 冲突：$($conflicts -join ', ')"
    }

    [array]$untracked = @(Invoke-GitLines `
            -Description '未跟踪文件列表' `
            -Arguments @('ls-files', '--others', '--exclude-standard'))
    if ($untracked.Count -gt 0) {
        throw "存在未跟踪文件，请确认后再发布：$($untracked -join ', ')"
    }

    [array]$indexFlags = @(Invoke-GitLines `
            -Description '暂存区标志' `
            -Arguments @('ls-files', '-v', '--'))
    [array]$abnormalIndexFlags = @(
        $indexFlags | Where-Object { $_ -cnotmatch '^H ' }
    )
    if ($abnormalIndexFlags.Count -gt 0) {
        throw (
            '仓库中存在 assume-unchanged、skip-worktree 或异常索引状态。' +
            '请先恢复所有文件的普通 Git 跟踪状态。'
        )
    }
}

function Get-GitBashPath {
    $gitCommand = Get-Command git
    $candidates = @(
        (Join-Path (Split-Path $gitCommand.Source -Parent) '..\bin\bash.exe')
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe')
    )
    $gitBash = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if (-not $gitBash) {
        throw '未找到 Git for Windows 自带的 bash.exe。'
    }
    return $gitBash
}

function Invoke-ReleaseChecks {
    param(
        [Parameter(Mandatory)][string]$GitBash,
        [Parameter(Mandatory)][string]$BashRepoRoot,
        [Parameter(Mandatory)][string[]]$ShellScripts,
        [Parameter(Mandatory)][string]$SensitivePattern
    )

    Invoke-Native -Name '运行 ShellCheck warning 级检查' -Command {
        & shellcheck --severity=warning @ShellScripts
    }

    $quotedBashRoot = "'" + $BashRepoRoot.Replace("'", "'\''") + "'"
    $bashCommand = (
        "cd $quotedBashRoot && " +
        'for file in vpsbox.sh tests/*.sh; do bash -n "$file" || exit 1; done'
    )
    Invoke-Native -Name '使用本地 Git Bash 运行 Bash 语法检查' -Command {
        & $GitBash -lc $bashCommand
    }

    Invoke-Native -Name '检查未暂存 Git 差异格式' -Command {
        & git diff --check
    }
    Invoke-Native -Name '检查已暂存 Git 差异格式' -Command {
        & git diff --cached --check
    }

    & git grep -q -I -E $SensitivePattern -- .
    $grepExitCode = $LASTEXITCODE
    if ($grepExitCode -eq 0) {
        throw '检测到疑似私钥或 GitHub Token，请先检查。'
    }
    if ($grepExitCode -ne 1) {
        throw "敏感信息检查执行失败，退出码：$grepExitCode"
    }
    $global:LASTEXITCODE = 0
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = Join-Path $repoRoot 'vpsbox.sh'
$readmePath = Join-Path $repoRoot 'README.md'
$testsPath = Join-Path $repoRoot 'tests'
$selfRelativePath = 'tools/release.ps1'
$sensitivePattern =
    'BEGIN ((OPENSSH|RSA|EC|DSA|ENCRYPTED) )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}'

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $readmePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $testsPath -PathType Container)) {
    throw '仓库结构不完整，找不到 vpsbox.sh、README.md 或 tests 目录。'
}

Push-Location $repoRoot
try {
    foreach ($commandName in 'git', 'shellcheck') {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "未找到依赖：$commandName"
        }
    }

    [array]$selfTracked = @(Invoke-GitLines `
            -Description "$selfRelativePath 跟踪状态" `
            -Arguments @('ls-files', '--error-unmatch', '--', $selfRelativePath))
    if ($selfTracked.Count -ne 1 -or $selfTracked[0] -cne $selfRelativePath) {
        throw "$selfRelativePath 必须是当前仓库正常跟踪的文件。"
    }

    Assert-RepositoryState
    [array]$workingTreeChanges = @(Invoke-GitLines `
            -Description '工作区状态' `
            -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))
    $statusBeforeChecks = $workingTreeChanges -join "`n"

    [byte[]]$scriptBytesBeforeChecks = [IO.File]::ReadAllBytes($scriptPath)
    [byte[]]$readmeBytesBeforeChecks = [IO.File]::ReadAllBytes($readmePath)
    $encoding = [Text.UTF8Encoding]::new($false)
    $scriptText = $encoding.GetString($scriptBytesBeforeChecks)
    $readmeText = $encoding.GetString($readmeBytesBeforeChecks)
    $currentVersion = Get-VersionFromText -Text $scriptText
    $currentReadmeVersion = Get-ReadmeVersionFromText -Text $readmeText
    if ($currentReadmeVersion -cne $currentVersion) {
        throw "当前版本不一致：vpsbox.sh 为 $currentVersion，README.md 为 $currentReadmeVersion。"
    }

    $headVersion = Get-HeadVersion
    $expectedVersion = Get-NextPatchVersion -Version $headVersion
    if ($Bump) {
        if ($currentVersion -notin $headVersion, $expectedVersion) {
            throw "当前版本 $currentVersion 既不等于 HEAD 的 $headVersion，也不是下一版本 $expectedVersion。"
        }
    }
    elseif ($workingTreeChanges.Count -gt 0 -and
        $currentVersion -cne $expectedVersion) {
        throw (
            "检测到待发布改动，版本必须由 $headVersion 增加至 $expectedVersion。" +
            '请运行：.\tools\release.ps1 -Bump'
        )
    }

    $gitBash = Get-GitBashPath
    $bashRepoRoot = $repoRoot.Replace('\', '/')
    [string[]]$shellScripts = @($scriptPath) +
        @(Get-ChildItem -LiteralPath $testsPath -Filter '*.sh' -File |
            Sort-Object FullName |
            ForEach-Object FullName)
    Invoke-ReleaseChecks `
        -GitBash $gitBash `
        -BashRepoRoot $bashRepoRoot `
        -ShellScripts $shellScripts `
        -SensitivePattern $sensitivePattern

    [array]$statusAfterChecks = @(Invoke-GitLines `
            -Description '检查后的工作区状态' `
            -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))
    if (($statusAfterChecks -join "`n") -cne $statusBeforeChecks) {
        throw '发布检查期间 Git 状态发生变化，请确认没有其他进程正在修改仓库后重试。'
    }

    [byte[]]$scriptBytesAfterChecks = [IO.File]::ReadAllBytes($scriptPath)
    [byte[]]$readmeBytesAfterChecks = [IO.File]::ReadAllBytes($readmePath)
    if ([Convert]::ToBase64String($scriptBytesAfterChecks) -cne
            [Convert]::ToBase64String($scriptBytesBeforeChecks) -or
        [Convert]::ToBase64String($readmeBytesAfterChecks) -cne
            [Convert]::ToBase64String($readmeBytesBeforeChecks)) {
        throw '发布检查期间版本文件发生变化，请重试。'
    }

    $versionChanged = $false
    if ($Bump -and $currentVersion -ceq $headVersion) {
        $updatedScriptText = [regex]::Replace(
            $scriptText,
            '(?m)^VPSBOX_VERSION="[^\"]+"\r?$',
            "VPSBOX_VERSION=`"$expectedVersion`""
        )
        $updatedReadmeText = Set-ReadmeVersionInText `
            -Text $readmeText `
            -Version $expectedVersion
        [byte[]]$updatedScriptBytes = $encoding.GetBytes($updatedScriptText)
        [byte[]]$updatedReadmeBytes = $encoding.GetBytes($updatedReadmeText)
        $writeAttempted = $false

        try {
            $writeAttempted = $true
            [IO.File]::WriteAllBytes($scriptPath, $updatedScriptBytes)
            [IO.File]::WriteAllBytes($readmePath, $updatedReadmeBytes)

            $currentVersion = Get-VersionFromText -Text (
                $encoding.GetString([IO.File]::ReadAllBytes($scriptPath))
            )
            $currentReadmeVersion = Get-ReadmeVersionFromText -Text (
                $encoding.GetString([IO.File]::ReadAllBytes($readmePath))
            )
            if ($currentVersion -cne $expectedVersion -or
                $currentReadmeVersion -cne $expectedVersion) {
                throw (
                    "改号后的版本不正确：预期 $expectedVersion，vpsbox.sh 为 " +
                    "$currentVersion，README.md 为 $currentReadmeVersion。"
                )
            }

            Invoke-Native -Name '复验改号后的 vpsbox.sh ShellCheck' -Command {
                & shellcheck --severity=warning $scriptPath
            }
            $quotedBashRoot = "'" + $bashRepoRoot.Replace("'", "'\''") + "'"
            $postBumpCommand = "cd $quotedBashRoot && bash -n vpsbox.sh"
            Invoke-Native -Name '复验改号后的 vpsbox.sh Bash 语法' -Command {
                & $gitBash -lc $postBumpCommand
            }
            Invoke-Native -Name '复验改号后的版本文件差异格式' -Command {
                & git diff --check -- vpsbox.sh README.md
            }

            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($scriptPath)) -cne
                    [Convert]::ToBase64String($updatedScriptBytes) -or
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($readmePath)) -cne
                    [Convert]::ToBase64String($updatedReadmeBytes)) {
                throw '改号后的版本文件在复验期间发生变化。'
            }
            $versionChanged = $true
        }
        catch {
            $bumpError = $_
            if ($writeAttempted) {
                [System.Collections.Generic.List[string]]$restoreErrors = @()
                try {
                    [IO.File]::WriteAllBytes($scriptPath, $scriptBytesBeforeChecks)
                }
                catch {
                    $restoreErrors.Add("vpsbox.sh：$($_.Exception.Message)")
                }
                try {
                    [IO.File]::WriteAllBytes($readmePath, $readmeBytesBeforeChecks)
                }
                catch {
                    $restoreErrors.Add("README.md：$($_.Exception.Message)")
                }
                if ($restoreErrors.Count -gt 0) {
                    throw (
                        "改号失败，且无法完整恢复版本文件：$($restoreErrors -join '；')" +
                        "；原错误：$($bumpError.Exception.Message)"
                    )
                }
                Write-Info "改号或复验失败，已恢复 vpsbox.sh 与 README.md：$headVersion"
            }
            throw $bumpError
        }
    }

    if ($Bump) {
        if ($versionChanged) {
            Write-Info "版本已同步更新：$headVersion -> $currentVersion"
        }
        else {
            Write-Info "版本已经是相对 HEAD 的下一补丁版本：$currentVersion"
        }
        Write-Info "预检和改号后复验全部通过，当前版本：$currentVersion"
        Write-Info '请统一暂存所有改动后，再运行 .\tools\release.ps1 做最终检查。'
    }
    else {
        Write-Info "发布前静态检查全部通过，当前版本：$currentVersion"
    }
    Write-Info '完整回归测试需在 Linux/WSL 中单独运行：bash tests/run.sh'
    Write-Info '本脚本没有执行提交或推送。'
}
finally {
    Pop-Location
}
