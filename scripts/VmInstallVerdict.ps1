# Pure verdicts for the VM install report. Windows PowerShell 5.1.

function Get-CombinedStatus($Parts) {
  foreach ($part in @($Parts)) {
    if ($part.Status -eq 'FAIL') { return 'FAIL' }
  }
  foreach ($part in @($Parts)) {
    if ($part.Status -eq 'NOT PROVEN') { return 'NOT PROVEN' }
  }
  foreach ($part in @($Parts)) {
    if ($part.Status -eq 'NOT RUN') { return 'NOT RUN' }
  }
  return 'PASS'
}

function Test-DisableAntiSpywareSetPolicy($Plan, $Events) {
  $inPlan = $false
  foreach ($item in @($Plan.Policies)) {
    if ($item -and [string]$item.Name -eq 'DisableAntiSpyware') { $inPlan = $true }
  }
  $inJournal = $false
  foreach ($event in @($Events)) {
    if (-not $event -or [string]$event.step -ne 'defender-post') { continue }
    foreach ($command in @($event.commands)) {
      if (-not $command) { continue }
      if ([string]$command.kind -eq 'Set-Policy' -and [string]$command.name -eq 'DisableAntiSpyware') { $inJournal = $true }
    }
  }
  return ($inPlan -or $inJournal)
}

function Get-DisableAntiSpywarePolicyVerdict($Plan, $Events) {
  if (Test-DisableAntiSpywareSetPolicy $Plan $Events) {
    return [pscustomobject]@{
      Status = 'FAIL'
      Detail = 'DisableAntiSpyware Set-Policy is present in the plan or the defender-post journal. A skipped or failed write is not a pass.'
    }
  }
  return [pscustomobject]@{
    Status = 'PASS'
    Detail = 'DisableAntiSpyware is absent from the plan and the defender-post journal.'
  }
}
