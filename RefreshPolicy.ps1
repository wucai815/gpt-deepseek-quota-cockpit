function Get-CodexRefreshPolicy($Snapshot, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow) {
    $resume=$null
    $unknownReset=$false
    foreach ($window in @($Snapshot.primary,$Snapshot.secondary)) {
        if ($null -eq $window -or $null -eq $window.remainingPercent -or $window.remainingPercent -gt 0) { continue }
        if ($null -eq $window.resetsAt) { $unknownReset=$true; continue }
        $reset=[DateTimeOffset]::FromUnixTimeSeconds([long]$window.resetsAt)
        if ($reset -gt $Now -and ($null -eq $resume -or $reset -gt $resume)) { $resume=$reset }
    }
    # Both windows must have recovered before the account can be useful again.
    [pscustomobject]@{paused=($unknownReset -or $null -ne $resume); resumeAt=$(if ($unknownReset) { $null } else { $resume })}
}

function Test-DeepSeekDepleted($Snapshot) {
    if ($null -eq $Snapshot) { return $false }
    if ($Snapshot.isAvailable -is [bool] -and -not $Snapshot.isAvailable) { return $true }
    $rows=@($Snapshot.balances)
    if ($rows.Count -eq 0) { return $false }
    foreach ($row in $rows) {
        # An absent currency value is unknown, not proof of depletion.
        if ($null -eq $row -or $null -eq $row.total -or $row.total -gt 0) { return $false }
    }
    return $true
}
