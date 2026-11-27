@{
    Severity = @('Error', 'Warning')

    # Interactive console utility scripts intentionally use Write-Host for colored user-facing status output.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
    )
}
