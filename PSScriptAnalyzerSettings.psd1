# Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                          # both scripts talk to a person in a console or write a log line
        'PSAvoidUsingEmptyCatchBlock',                    # log rotation, clipboard and logout are best-effort on purpose
        'PSReviewUnusedParameter',                        # script parameters are read inside functions; the rule can't see that
        'PSAvoidUsingConvertToSecureStringWithPlainText'  # install.ps1 encrypts a password it just generated
    )
}
