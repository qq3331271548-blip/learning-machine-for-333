# Stop hook: fires right before Claude finishes a turn.
# If this turn left UNREVIEWED web-code changes, it blocks the stop and forces a
# fresh-eyes self-review + verify pass first. Otherwise it allows the stop.
#
# Loop-safe via stop_hook_active. A state file remembers the last-reviewed
# code state, so turns that did not touch code do not re-trigger a review.
# ANY error => fail open (allow the stop). We never trap the user in a loop.
#
# v2: Uses `git diff --name-only` for precise file-level detection instead of
#     regex-matching the full status output. Avoids false positives from
#     non-web-code untracked files (jsonl, md, etc.).

try {
    $ErrorActionPreference = 'SilentlyContinue'

    # Project root
    $proj = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrWhiteSpace($proj)) {
        $proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    Set-Location -LiteralPath $proj

    # Read the hook payload from stdin (contains stop_hook_active).
    $raw = [Console]::In.ReadToEnd()
    $active = $false
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { $active = [bool]((ConvertFrom-Json $raw).stop_hook_active) } catch {}
    }

    $stateFile = Join-Path $proj '.claude\.last-review'

    # ---- precise web-code detection ----
    # Collect all file paths that changed (staged, unstaged, untracked)
    $changed = @()
    $changed += (git diff --name-only HEAD) 2>$null
    $changed += (git diff --name-only --cached) 2>$null
    $changed += (git ls-files --others --exclude-standard) 2>$null
    $changed = ($changed | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $proj $_)) })

    # Only .html / .css / .js files count as web-code
    $webFiles = $changed | Where-Object { $_ -match '\.(html|css|js)$' }

    # Fingerprint the current state from web-code files only
    $sig = ''
    foreach ($f in ($webFiles | Sort-Object)) {
        $content = ''
        try { $content = (Get-Content -LiteralPath (Join-Path $proj $f) -Raw -Encoding UTF8) } catch {}
        $sig += "$f`n$content`n===END==="
    }
    $sha    = [Security.Cryptography.SHA1]::Create()
    $hash   = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-','')

    # SECOND stop after review pass -> record state, allow
    if ($active) {
        Set-Content -LiteralPath $stateFile -Value $hash -Encoding ASCII
        exit 0
    }

    # No web-code files changed -> allow
    if (-not $webFiles) { exit 0 }

    # Identical to last-reviewed state -> allow
    $last = ''
    if (Test-Path -LiteralPath $stateFile) { $last = (Get-Content -LiteralPath $stateFile -Raw).Trim() }
    if ($hash -eq $last) { exit 0 }

    # Unreviewed web-code changes -> BLOCK
    $reason = @'
There are unreviewed web-code changes in this turn. Before finishing, run a self-review the way a SEPARATE reviewer would. Do NOT just re-read your own code from memory: that carries your authoring intent and hides the exact bugs you missed while writing.

1. Use the Task tool to spawn a SUBAGENT (clean context, no memory of how you wrote this) as a skeptical reviewer. Instruct it to: re-read the changed files, compare them against the ORIGINAL requirement of this task, and assume bugs exist. Have it check: does the feature truly match the requirement, edge cases, likely console errors, responsive / mobile layout, and whether the interactions actually work.
2. Fix the confirmed problems it reports. For anything uncertain, list it and ask the user rather than making large unrequested changes.
3. Use the verify skill to actually run the page and observe it (console output + click through the interactions).
4. Report briefly IN CHINESE: what was found, what you changed, and what still needs the user's decision.

Then finish normally. This prompt will not fire again for the same set of changes.
'@

    $out = @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
    [Console]::Out.Write($out)
    exit 0
}
catch {
    # Anything unexpected: allow the stop. Never block the user on a hook error.
    exit 0
}
