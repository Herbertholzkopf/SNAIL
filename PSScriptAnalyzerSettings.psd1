# Einstellungen für PSScriptAnalyzer (Prüfung auf Linux mit PowerShell 7):
#   Invoke-ScriptAnalyzer -Path .\Projekt-Installer.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
#   Invoke-ScriptAnalyzer -Path .\tests\SNAIL.Tests.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
# Ausgeschlossen sind nur Regeln, die bewusst anders gelöst sind:
#   - PositionalParameters, ShouldProcess, SingularNouns, ApprovedVerbs:
#     Stil des Skripts (WinForms-Helfer wie New-Label, keine Cmdlets für die Pipeline).
#   - PlainTextForPassword: Passwörter werden als Zeichenkette erzeugt und
#     geschützt in Dateien geschrieben; SecureString brächte hier nichts.
#   - OverwritingBuiltInCmdlets: Write-Log gibt es in Windows PowerShell 5.1 nicht.
#   - EmptyCatchBlock: alle leeren catch-Blöcke sind gewollt (Aufräumen,
#     optionale Abfragen wie Rechte nachziehen oder Bildschirmgröße).
@{
    ExcludeRules = @(
        'PSAvoidUsingPositionalParameters'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        'PSUseApprovedVerbs'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidOverwritingBuiltInCmdlets'
        'PSAvoidUsingEmptyCatchBlock'
        'PSAvoidUsingWriteHost'      # nur Build-Projekt-Installer.ps1, New-Icon.ps1, tests (Konsolenausgabe)
    )
}
