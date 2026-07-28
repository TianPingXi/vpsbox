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

function Get-VersionFromText {
    param([Parameter(Mandatory)][string]$Text)

    $matches = [regex]::Matches(
        $Text,
        '(?m)^VPSBOX_VERSION="(v[0-9]+\.[0-9]+\.[0-9]+)"\r?$'
    )
    if ($matches.Count -ne 1) {
        throw 'vpsbox.sh 必须且只能包含一个格式正确的 VPSBOX_VERSION。'
    }
    return $matches[0].Groups[1].Value
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

function Assert-NextPatchVersionRules {
    foreach ($case in @(
            [pscustomobject]@{ Current = 'v1.0.44'; Expected = 'v1.0.45' }
            [pscustomobject]@{ Current = 'v1.0.99'; Expected = 'v1.1.0' }
            [pscustomobject]@{ Current = 'v1.99.99'; Expected = 'v1.100.0' }
        )) {
        $actual = Get-NextPatchVersion -Version $case.Current
        if ($actual -cne $case.Expected) {
            throw (
                "版本递增规则断言失败：$($case.Current) 应得到 " +
                "$($case.Expected)，实际为 $actual"
            )
        }
    }

    $invalidRejected = $false
    try {
        [void](Get-NextPatchVersion -Version 'v1.0.100')
    }
    catch {
        $invalidRejected = $true
    }
    if (-not $invalidRejected) {
        throw '版本递增规则断言失败：补丁位大于 99 时必须拒绝。'
    }
}

function Get-HeadVersion {
    $headText = (& git show HEAD:vpsbox.sh 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw '无法读取 HEAD 中的 vpsbox.sh。'
    }
    return Get-VersionFromText -Text $headText
}

function Get-WorkingTreeChanges {
    [array]$changes = @(& git status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw '无法读取 Git 工作区状态。'
    }
    return $changes
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-ByteArrayEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    return (Get-Sha256Hex -Bytes $Left) -ceq (Get-Sha256Hex -Bytes $Right)
}

function Read-OpenFileBytes {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)

    if ($Stream.Length -gt [int]::MaxValue) {
        throw 'vpsbox.sh 过大，无法安全读取。'
    }
    [byte[]]$bytes = New-Object byte[] ([int]$Stream.Length)
    $Stream.Position = 0
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
        if ($read -le 0) {
            throw '读取 vpsbox.sh 时意外到达文件末尾。'
        }
        $offset += $read
    }
    return ,$bytes
}

function Write-OpenFileBytes {
    param(
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $Stream.Position = 0
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.SetLength($Bytes.Length)
    $Stream.Flush($true)
}

function Get-GitTextForFingerprint {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        [array]$output = @(& git @Arguments 2>$null)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "无法读取用于发布检查的 Git 状态：$Description"
    }
    return $output -join "`n"
}

function Get-RepositoryStateFingerprint {
    param(
        [Parameter(Mandatory)][string]$ReleaseScriptPath,
        [switch]$ExcludeVpsbox
    )

    [string[]]$pathspec = @('--')
    if ($ExcludeVpsbox) {
        $pathspec = @('--', '.', ':(exclude)vpsbox.sh')
    }

    $head = Get-GitTextForFingerprint `
        -Description 'HEAD' `
        -Arguments @('rev-parse', '--verify', 'HEAD')
    $status = Get-GitTextForFingerprint `
        -Description '工作区' `
        -Arguments (@('status', '--porcelain=v1', '--untracked-files=all') + $pathspec)
    $stagedDiff = Get-GitTextForFingerprint `
        -Description '已暂存差异' `
        -Arguments (@('diff', '--cached', '--no-ext-diff', '--binary') + $pathspec)
    $unstagedDiff = Get-GitTextForFingerprint `
        -Description '未暂存差异' `
        -Arguments (@('diff', '--no-ext-diff', '--binary') + $pathspec)

    [byte[]]$releaseScriptBytes = [IO.File]::ReadAllBytes($ReleaseScriptPath)
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $components = @(
        "head:$head"
        "status:$(Get-Sha256Hex -Bytes ($utf8NoBom.GetBytes($status)))"
        "staged:$(Get-Sha256Hex -Bytes ($utf8NoBom.GetBytes($stagedDiff)))"
        "unstaged:$(Get-Sha256Hex -Bytes ($utf8NoBom.GetBytes($unstagedDiff)))"
        "release:$(Get-Sha256Hex -Bytes $releaseScriptBytes)"
    ) -join "`n"
    return Get-Sha256Hex -Bytes ($utf8NoBom.GetBytes($components))
}

function Get-RepositoryIndexFingerprint {
    $vpsboxIndexEntry = Get-GitTextForFingerprint `
        -Description 'vpsbox.sh 暂存区条目' `
        -Arguments @('ls-files', '--stage', '--', 'vpsbox.sh')
    $repositoryIndexFlags = Get-GitTextForFingerprint `
        -Description '仓库暂存区标志' `
        -Arguments @('ls-files', '-v', '--')

    [array]$vpsboxIndexEntryLines = @($vpsboxIndexEntry -split "`n")
    if ($vpsboxIndexEntryLines.Count -ne 1 -or
        $vpsboxIndexEntryLines[0] -notmatch
            '^(100644|100755) [0-9a-f]+ 0\tvpsbox\.sh$') {
        throw (
            'vpsbox.sh 存在异常索引类型。' +
            '请先恢复普通 Git 跟踪状态。'
        )
    }

    [array]$abnormalIndexFlags = @(
        @($repositoryIndexFlags -split "`n") |
            Where-Object { $_ -cnotmatch '^H ' }
    )
    if ($abnormalIndexFlags.Count -gt 0) {
        throw (
            '仓库中存在 assume-unchanged、skip-worktree 或异常索引状态。' +
            '请先恢复所有文件的普通 Git 跟踪状态。'
        )
    }

    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    return Get-Sha256Hex -Bytes (
        $utf8NoBom.GetBytes(
            "$vpsboxIndexEntry`n$repositoryIndexFlags"
        )
    )
}

function Assert-NoMixedStagingState {
    [array]$stagedPaths = @(& git diff --cached --name-only --diff-filter=ACDMRTUXB)
    if ($LASTEXITCODE -ne 0) {
        throw '无法读取已暂存文件列表。'
    }
    [array]$unstagedPaths = @(& git diff --name-only --diff-filter=ACDMRTUXB)
    if ($LASTEXITCODE -ne 0) {
        throw '无法读取未暂存文件列表。'
    }

    if ($stagedPaths.Count -gt 0 -and $unstagedPaths.Count -gt 0) {
        throw (
            '检测到已暂存和未暂存改动同时存在，无法确认待提交内容与已检查工作树一致。' +
            '请先统一暂存全部改动，或取消暂存后重试。'
        )
    }
}

function Update-VersionIfNeeded {
    param(
        [Parameter(Mandatory)][IO.FileStream]$ScriptStream,
        [Parameter(Mandatory)][string]$CurrentText,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$HeadVersion
    )

    $expectedVersion = Get-NextPatchVersion -Version $HeadVersion

    if ($CurrentVersion -eq $expectedVersion) {
        Write-Info "版本已经是相对 HEAD 的下一补丁版本：$CurrentVersion"
        return $CurrentText
    }
    if ($CurrentVersion -ne $HeadVersion) {
        throw "当前版本 $CurrentVersion 既不等于 HEAD 的 $HeadVersion，也不是下一版本 $expectedVersion。"
    }

    $updatedText = [regex]::Replace(
        $CurrentText,
        '(?m)^VPSBOX_VERSION="[^"]+"\r?$',
        "VPSBOX_VERSION=`"$expectedVersion`""
    )
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    Write-OpenFileBytes `
        -Stream $ScriptStream `
        -Bytes ($utf8NoBom.GetBytes($updatedText))
    Write-Info "版本已更新：$CurrentVersion -> $expectedVersion"
    return $updatedText
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = Join-Path $repoRoot 'vpsbox.sh'
$testsPath = Join-Path $repoRoot 'tests'
$selfRelativePath = 'tools/release.ps1'
$releaseScriptPath = Join-Path $repoRoot $selfRelativePath

Assert-NextPatchVersionRules

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $testsPath -PathType Container)) {
    throw '仓库结构不完整，找不到 vpsbox.sh 或 tests 目录。'
}

$scriptStream = $null
Push-Location $repoRoot
try {
    foreach ($commandName in 'git', 'shellcheck') {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "未找到依赖：$commandName"
        }
    }

    $scriptAccess = [IO.FileAccess]::Read
    if ($Bump) {
        $scriptAccess = [IO.FileAccess]::ReadWrite
    }
    $scriptStream = [IO.File]::Open(
        $scriptPath,
        [IO.FileMode]::Open,
        $scriptAccess,
        [IO.FileShare]::Read
    )

    [byte[]]$scriptBytesBeforeChecks = Read-OpenFileBytes -Stream $scriptStream
    $scriptEncoding = [Text.UTF8Encoding]::new($false)
    $scriptText = $scriptEncoding.GetString($scriptBytesBeforeChecks)
    $repositoryStateBeforeChecks = Get-RepositoryStateFingerprint `
        -ReleaseScriptPath $releaseScriptPath
    $repositoryStateWithoutVpsboxBeforeChecks = Get-RepositoryStateFingerprint `
        -ReleaseScriptPath $releaseScriptPath `
        -ExcludeVpsbox
    $repositoryIndexBeforeChecks = Get-RepositoryIndexFingerprint
    $currentVersion = Get-VersionFromText -Text $scriptText
    $headVersion = Get-HeadVersion
    if ($Bump) {
        $expectedVersion = Get-NextPatchVersion -Version $headVersion
        if ($currentVersion -notin $headVersion, $expectedVersion) {
            throw "当前版本 $currentVersion 既不等于 HEAD 的 $headVersion，也不是下一版本 $expectedVersion。"
        }
    }
    [array]$workingTreeChanges = @(Get-WorkingTreeChanges)
    Assert-NoMixedStagingState
    if (-not $Bump -and $workingTreeChanges.Count -gt 0) {
        $expectedVersion = Get-NextPatchVersion -Version $headVersion
        if ($currentVersion -ne $expectedVersion) {
            throw "检测到待发布改动，版本必须由 $headVersion 增加至 $expectedVersion。请运行：.\tools\release.ps1 -Bump"
        }
    }

    $shellScripts = @($scriptPath) +
        @(Get-ChildItem -LiteralPath $testsPath -Filter '*.sh' -File |
            Sort-Object FullName |
            ForEach-Object FullName)
    Invoke-Native -Name '运行 ShellCheck warning 级检查' -Command {
        & shellcheck --severity=warning @shellScripts
    }

    $gitCommand = Get-Command git
    $gitBashCandidates = @(
        (Join-Path (Split-Path $gitCommand.Source -Parent) '..\bin\bash.exe'),
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe')
    )
    $gitBash = $gitBashCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if (-not $gitBash) {
        throw '未找到 Git for Windows 自带的 bash.exe。'
    }
    $bashRepoRoot = $repoRoot.Replace('\', '/')
    $quotedBashRoot = "'" + $bashRepoRoot.Replace("'", "'\''") + "'"
    $bashCommand = (
        "cd $quotedBashRoot && " +
        'for file in vpsbox.sh tests/*.sh; do bash -n "$file" || exit 1; done'
    )
    Invoke-Native -Name '使用本地 Git Bash 运行 Bash 语法检查' -Command {
        & $gitBash -lc $bashCommand
    }

    Invoke-Native -Name '检查未暂存 Git 差异格式' -Command {
        & git diff --check
    }
    Invoke-Native -Name '检查已暂存 Git 差异格式' -Command {
        & git diff --cached --check
    }

    [array]$conflicts = @(& git diff --name-only --diff-filter=U) +
        @(& git diff --cached --name-only --diff-filter=U)
    if ($conflicts.Count -gt 0) {
        throw "存在尚未解决的 Git 冲突：$($conflicts -join ', ')"
    }

    $selfTrackedPath = Get-GitTextForFingerprint `
        -Description "$selfRelativePath 跟踪状态" `
        -Arguments @('ls-files', '--', $selfRelativePath)
    if ($selfTrackedPath.Length -gt 0 -and
        $selfTrackedPath -cne $selfRelativePath) {
        throw "无法可靠判断 $selfRelativePath 的跟踪状态。"
    }
    $selfIsTracked = $selfTrackedPath -ceq $selfRelativePath
    $selfHeadPath = Get-GitTextForFingerprint `
        -Description "$selfRelativePath HEAD 跟踪状态" `
        -Arguments @('ls-tree', '--name-only', 'HEAD', '--', $selfRelativePath)
    if ($selfHeadPath.Length -gt 0 -and
        $selfHeadPath -cne $selfRelativePath) {
        throw "无法可靠判断 HEAD 中 $selfRelativePath 的跟踪状态。"
    }
    $selfWasTrackedInHead = $selfHeadPath -ceq $selfRelativePath
    if (-not $selfIsTracked -and $selfWasTrackedInHead) {
        throw (
            "$selfRelativePath 已从暂存区删除，但工作树中仍有同名文件。" +
            '请先恢复正常跟踪状态或明确完成删除。'
        )
    }

    [array]$untracked = @(
        @(& git ls-files --others --exclude-standard) |
            Where-Object { $_ -ne $selfRelativePath }
    )
    if ($LASTEXITCODE -ne 0) {
        throw '无法读取未跟踪文件列表。'
    }
    if ($untracked.Count -gt 0) {
        throw "存在未跟踪文件，请确认后再发布：$($untracked -join ', ')"
    }
    if (-not $selfIsTracked) {
        [array]$selfDiffCheck = @(
            & git -c core.autocrlf=false diff --no-index --check -- NUL $selfRelativePath 2>&1
        )
        $selfDiffExitCode = $LASTEXITCODE
        if ($selfDiffExitCode -notin 0, 1, 2, 3) {
            throw "$selfRelativePath 格式检查执行失败，退出码：$selfDiffExitCode"
        }
        if ($selfDiffExitCode -in 2, 3 -or $selfDiffCheck.Count -gt 0) {
            throw "$selfRelativePath 存在差异格式问题：$($selfDiffCheck -join '; ')"
        }
    }

    $sensitivePattern =
        'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}'
    & git grep -q -I -E $sensitivePattern -- .
    $grepExitCode = $LASTEXITCODE
    if ($grepExitCode -eq 0) {
        throw '检测到疑似私钥或 GitHub Token，请先检查。'
    }
    if ($grepExitCode -ne 1) {
        throw "敏感信息检查执行失败，退出码：$grepExitCode"
    }
    if (-not $selfIsTracked) {
        & git grep --no-index -q -I -E $sensitivePattern -- $selfRelativePath
        $selfGrepExitCode = $LASTEXITCODE
        if ($selfGrepExitCode -eq 0) {
            throw "$selfRelativePath 检测到疑似私钥或 GitHub Token，请先检查。"
        }
        if ($selfGrepExitCode -ne 1) {
            throw "$selfRelativePath 敏感信息检查执行失败，退出码：$selfGrepExitCode"
        }
    }
    $global:LASTEXITCODE = 0

    $repositoryStateAfterChecks = Get-RepositoryStateFingerprint `
        -ReleaseScriptPath $releaseScriptPath
    if ($repositoryStateAfterChecks -cne $repositoryStateBeforeChecks) {
        throw (
            '发布检查期间仓库状态发生变化，检查结果已失效。' +
            '脚本没有修改版本号，请确认没有其他进程或编辑器正在写入后重试。'
        )
    }
    $repositoryIndexAfterPreflight = Get-RepositoryIndexFingerprint
    if ($repositoryIndexAfterPreflight -cne $repositoryIndexBeforeChecks) {
        throw '发布检查期间仓库索引状态发生变化，检查结果已失效。'
    }
    [byte[]]$scriptBytesAfterChecks = Read-OpenFileBytes -Stream $scriptStream
    if (-not (Test-ByteArrayEqual `
            -Left $scriptBytesBeforeChecks `
            -Right $scriptBytesAfterChecks)) {
        throw (
            '发布检查期间 vpsbox.sh 发生变化，检查结果已失效。' +
            '脚本没有覆盖当前文件，请重试。'
        )
    }

    if ($Bump) {
        $restoreVersionOnFailure = $currentVersion -eq $headVersion
        $versionWriteAttempted = $false
        [byte[]]$scriptBytesAfterBump = @()
        try {
            $repositoryStateBeforeVersionWrite = Get-RepositoryStateFingerprint `
                -ReleaseScriptPath $releaseScriptPath
            if ($repositoryStateBeforeVersionWrite -cne $repositoryStateBeforeChecks) {
                throw (
                    '预检完成后仓库状态又发生变化，已停止改号。' +
                    '脚本没有覆盖当前文件，请重试。'
                )
            }
            [byte[]]$scriptBytesBeforeWrite = Read-OpenFileBytes -Stream $scriptStream
            if (-not (Test-ByteArrayEqual `
                    -Left $scriptBytesBeforeChecks `
                    -Right $scriptBytesBeforeWrite)) {
                throw (
                    '预检完成后 vpsbox.sh 又发生变化，已停止改号。' +
                    '脚本没有覆盖当前文件，请重试。'
                )
            }

            $expectedVersion = Get-NextPatchVersion -Version $headVersion
            $expectedScriptText = [regex]::Replace(
                $scriptEncoding.GetString($scriptBytesBeforeWrite),
                '(?m)^VPSBOX_VERSION="[^"]+"\r?$',
                "VPSBOX_VERSION=`"$expectedVersion`""
            )
            $scriptBytesAfterBump = $scriptEncoding.GetBytes($expectedScriptText)
            $versionWriteAttempted = $true
            $scriptText = Update-VersionIfNeeded `
                -ScriptStream $scriptStream `
                -CurrentText ($scriptEncoding.GetString($scriptBytesBeforeWrite)) `
                -CurrentVersion $currentVersion `
                -HeadVersion $headVersion
            $currentVersion = Get-VersionFromText -Text $scriptText

            if ($currentVersion -ne $expectedVersion) {
                throw "改号后的版本不正确：预期 $expectedVersion，实际 $currentVersion。"
            }
            if ($restoreVersionOnFailure) {
                [byte[]]$currentScriptBytes = Read-OpenFileBytes -Stream $scriptStream
                if (-not (Test-ByteArrayEqual `
                        -Left $scriptBytesAfterBump `
                        -Right $currentScriptBytes)) {
                    throw '改号后的 vpsbox.sh 与预期内容不一致。'
                }
                $repositoryStateWithoutVpsboxAfterWrite = Get-RepositoryStateFingerprint `
                    -ReleaseScriptPath $releaseScriptPath `
                    -ExcludeVpsbox
                $repositoryIndexAfterWrite = Get-RepositoryIndexFingerprint
                if ($repositoryStateWithoutVpsboxAfterWrite -cne
                        $repositoryStateWithoutVpsboxBeforeChecks -or
                    $repositoryIndexAfterWrite -cne
                        $repositoryIndexBeforeChecks) {
                    throw '改号期间仓库中的其他状态发生变化，检查结果已失效。'
                }

                Invoke-Native -Name '复验改号后的 vpsbox.sh ShellCheck' -Command {
                    & shellcheck --severity=warning $scriptPath
                }
                $postBumpBashCommand = "cd $quotedBashRoot && bash -n vpsbox.sh"
                Invoke-Native -Name '复验改号后的 vpsbox.sh Bash 语法' -Command {
                    & $gitBash -lc $postBumpBashCommand
                }
                Invoke-Native -Name '复验改号后的 vpsbox.sh 差异格式' -Command {
                    & git diff --check -- vpsbox.sh
                }

                [byte[]]$currentScriptBytes = Read-OpenFileBytes -Stream $scriptStream
                if (-not (Test-ByteArrayEqual `
                        -Left $scriptBytesAfterBump `
                        -Right $currentScriptBytes)) {
                    throw '改号后的复验期间 vpsbox.sh 发生变化，检查结果已失效。'
                }
                $repositoryStateWithoutVpsboxAfterChecks = Get-RepositoryStateFingerprint `
                    -ReleaseScriptPath $releaseScriptPath `
                    -ExcludeVpsbox
                $repositoryIndexAfterChecks = Get-RepositoryIndexFingerprint
                if ($repositoryStateWithoutVpsboxAfterChecks -cne
                        $repositoryStateWithoutVpsboxBeforeChecks -or
                    $repositoryIndexAfterChecks -cne
                        $repositoryIndexBeforeChecks) {
                    throw '改号后的复验期间仓库中的其他状态发生变化，检查结果已失效。'
                }
            }
        }
        catch {
            $bumpError = $_
            if ($restoreVersionOnFailure -and $versionWriteAttempted) {
                try {
                    [byte[]]$currentScriptBytes = Read-OpenFileBytes -Stream $scriptStream
                    if (Test-ByteArrayEqual `
                            -Left $scriptBytesBeforeChecks `
                            -Right $currentScriptBytes) {
                        Write-Info '改号或复验失败，vpsbox.sh 仍为原文件，无需恢复。'
                    }
                    else {
                        $versionWriteWasComplete = Test-ByteArrayEqual `
                            -Left $scriptBytesAfterBump `
                            -Right $currentScriptBytes
                        Write-OpenFileBytes `
                            -Stream $scriptStream `
                            -Bytes $scriptBytesBeforeChecks
                        [byte[]]$restoredScriptBytes =
                            Read-OpenFileBytes -Stream $scriptStream
                        if (-not (Test-ByteArrayEqual `
                                -Left $scriptBytesBeforeChecks `
                                -Right $restoredScriptBytes)) {
                            throw '恢复后 vpsbox.sh 与原始内容不一致。'
                        }
                        if ($versionWriteWasComplete) {
                            Write-Info "改号后的复验失败，已恢复原版本：$headVersion"
                        }
                        else {
                            Write-Info "改号写入不完整，已恢复原版本：$headVersion"
                        }
                    }
                }
                catch {
                    throw (
                        "改号或复验失败，且无法恢复原 vpsbox.sh：$($_.Exception.Message)" +
                        "；原错误：$($bumpError.Exception.Message)"
                    )
                }
            }
            throw $bumpError
        }
    }

    if (-not ($Bump -and $restoreVersionOnFailure)) {
        $repositoryStateBeforeSuccess = Get-RepositoryStateFingerprint `
            -ReleaseScriptPath $releaseScriptPath
        if ($repositoryStateBeforeSuccess -cne $repositoryStateBeforeChecks) {
            throw '最终确认前仓库状态发生变化，检查结果已失效。'
        }
        $repositoryIndexBeforeSuccess = Get-RepositoryIndexFingerprint
        if ($repositoryIndexBeforeSuccess -cne
                $repositoryIndexBeforeChecks) {
            throw '最终确认前仓库索引状态发生变化，检查结果已失效。'
        }
        [byte[]]$scriptBytesBeforeSuccess = Read-OpenFileBytes -Stream $scriptStream
        if (-not (Test-ByteArrayEqual `
                -Left $scriptBytesBeforeChecks `
                -Right $scriptBytesBeforeSuccess)) {
            throw '最终确认前 vpsbox.sh 发生变化，检查结果已失效。'
        }
    }

    if ($Bump -and $restoreVersionOnFailure) {
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
    if ($null -ne $scriptStream) {
        $scriptStream.Dispose()
    }
    Pop-Location
}
