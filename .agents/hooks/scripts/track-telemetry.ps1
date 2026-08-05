# Telemetry tracking hook for Azure Copilot Skills
# Reads JSON input from stdin, tracks relevant events, and publishes via MCP
#
# === Client Format Reference ===
#
# Copilot CLI:
#   - Field names:    camelCase (toolName, sessionId, toolArgs)
#   - Tool names:     lowercase (skill, view)
#   - MCP prefix:     azure-<command>  (e.g., azure-documentation)
#   - Skill prefix:   none (skill name as-is)
#   - Detection:      COPILOT_CLI env var is "1" (>=0.0.421); fallback: "toolArgs" without "hook_event_name" (<0.0.421)
#
# Claude Code:
#   - Field names:    snake_case (tool_name, session_id, tool_input, hook_event_name)
#   - Tool names:     PascalCase (Skill, Read, Edit)
#   - MCP prefix:     mcp__plugin_azure_azure__<command>  (double underscores)
#   - Skill prefix:   azure:<skill-name>  (e.g., azure:azure-prepare)
#   - Detection:      has "hook_event_name", tool_use_id does NOT contain "__vscode"
#
# VS Code:
#   - Field names:    snake_case (tool_name, session_id, tool_input, hook_event_name)
#   - Tool names:     snake_case (read_file, replace_string_in_file)
#   - MCP prefix:     mcp_azure_mcp_<command>  (e.g., mcp_azure_mcp_documentation)
#   - Skill paths:    .vscode/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/azure-skills/skills/<name>/SKILL.md          (VS Code)
#                     .vscode-insiders/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/azure-skills/skills/<name>/SKILL.md (VS Code Insiders)
#                     .agents/skills/<name>/SKILL.md
#   - Detection:      has "hook_event_name", tool_use_id contains "__vscode"
#                     or transcript_path contains "Code"
#   - Client name:    "Visual Studio Code" (stable) or "Visual Studio Code - Insiders"
#                     derived from transcript_path (e.g., .../Code - Insiders/User/...)
#   - Note:           Skills under .agents/skills/ are tracked as "Visual Studio Code" but
#                     transcript_path may be absent, so stable vs Insiders can only be
#                     distinguished when skills are called from agent-plugins (which
#                     includes transcript_path)
#
# === Event Types ===
#
# 1. skill_invocation
#    - Triggered when: the "skill"/"Skill" tool is called with a skill name,
#      OR a SKILL.md file is read from a recognized azure-skills path
#    - Tracked field: --skill-name <name>
#
# 2. tool_invocation
#    - Triggered when: a tool matching an Azure MCP prefix is called
#      (azure-*, mcp__plugin_azure_azure__*, mcp_azure_mcp_*)
#    - Tracked field: --tool-name <toolName>
#
# 3. reference_file_read
#    - Triggered when: a file read tool (view/Read/read_file) targets a file
#      inside a recognized azure-skills path that is NOT a SKILL.md
#    - These are the reference/instruction files that skills bundle alongside
#      SKILL.md (e.g., recipes, templates, requirement docs)
#    - Tracked field: --file-reference <relative-path-after-skills/>
#    - Example: azure-validate/references/recipes/azd/README.md
#
# === Reference File Detection ===
#
# When a file read tool is invoked (Copilot CLI: "view", Claude Code: "Read",
# VS Code: "read_file"), the script extracts the file path from the tool input
# and checks if it falls within a recognized azure-skills folder:
#
#   Path field lookup order:
#     - toolArgs.path / toolArgs.filePath       (Copilot CLI)
#     - tool_input.filePath / tool_input.file_path / tool_input.path  (Claude Code / VS Code)
#
#   Recognized azure-skills install paths:
#     - .copilot/installed-plugins/azure-skills/azure/skills/...
#     - .claude/plugins/cache/azure-skills/azure/<version>/skills/...
#     - .claude/plugins/cache/claude-plugins-official/azure/<version>/skills/...
#     - .vscode/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/azure-skills/skills/...
#     - .agents/skills/...
#
#   If the path matches AND is not a SKILL.md file, the relative path after
#   "skills/" is extracted and emitted as a reference_file_read event.
#   SKILL.md reads are tracked as skill_invocation instead (not double-counted).

$ErrorActionPreference = "SilentlyContinue"

# Skip telemetry if opted out
if ($env:AZURE_MCP_COLLECT_TELEMETRY -eq "false") {
    Write-Output '{"continue":true}'
    exit 0
}

# Return success and exit
function Write-Success {
    Write-Output '{"continue":true}'
    exit 0
}

# === Main Processing ===

# Read entire stdin at once - hooks send one complete JSON per invocation
try {
    $rawInput = [Console]::In.ReadToEnd()
}
catch {
    Write-Success
}

# Return success and exit if no input
if ([string]::IsNullOrWhiteSpace($rawInput)) {
    Write-Success
}

# === STEP 1: Read and parse input ===

# Parse JSON input
try {
    $inputData = $rawInput | ConvertFrom-Json
}
catch {
    Write-Success
}

# Extract fields from hook data
# Support Copilot CLI (camelCase), Claude Code (snake_case), and VS Code (snake_case) formats
$toolName = $inputData.toolName
if (-not $toolName) {
    $toolName = $inputData.tool_name
}

$sessionId = $inputData.sessionId
if (-not $sessionId) {
    $sessionId = $inputData.session_id
}

# Get tool arguments (Copilot CLI: toolArgs, Claude Code / VS Code: tool_input)
$toolInput = $inputData.toolArgs
if (-not $toolInput) {
    $toolInput = $inputData.tool_input
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Detect client name based on input format
# Copilot CLI (>=0.0.421): COPILOT_CLI env var is "1" — primary signal, checked first
# Copilot CLI (<0.0.421):  has "toolArgs" field without "hook_event_name" — backward compat fallback
# VS Code: has hook_event_name AND tool_use_id contains "__vscode" or transcript_path contains "Code"
# Claude Code: has hook_event_name, tool_use_id does NOT contain "__vscode"
$hasHookEventName = $inputData.PSObject.Properties.Name -contains "hook_event_name"
$hasToolArgs = $inputData.PSObject.Properties.Name -contains "toolArgs"
$toolUseId = $inputData.tool_use_id
$transcriptPath = $inputData.transcript_path
$isVscodeToolUseId = $toolUseId -and ($toolUseId -match '__vscode')
# Match path separators around "Code" or "Code - Insiders" to avoid matching "Claude Code"
$isVscodeTranscript = $transcriptPath -and ($transcriptPath -match '[/\\]Code( - Insiders)?[/\\]')

# Copilot CLI check first — env var available since v0.0.421
if ($env:COPILOT_CLI -eq "1") {
    $clientName = "copilot-cli"
}
elseif ($hasHookEventName -and ($isVscodeToolUseId -or $isVscodeTranscript)) {
    # Detect VS Code variant from transcript_path
    # Insiders: ...AppData\Roaming\Code - Insiders\User\...
    # Stable:   ...AppData\Roaming\Code\User\...
    if ($transcriptPath -match '[/\\]Code - Insiders[/\\]') {
        $clientName = "Visual Studio Code - Insiders"
    }
    else {
        $clientName = "Visual Studio Code"
    }
}
elseif ($hasHookEventName) {
    $clientName = "claude-code"
}
elseif ($hasToolArgs) {
    # Backward compat: old Copilot CLI (<0.0.421) sent toolArgs without hook_event_name
    # Claude Code never sends toolArgs, so this is unambiguous
    $clientName = "copilot-cli"
}
else {
    $clientName = "unknown"
}

# Skip if no tool name found in any format
if (-not $toolName) {
    Write-Success
}

# Helper to extract path from tool input (handles 'path', 'filePath', 'file_path')
function Get-ToolInputPath {
    if ($toolInput.path) { return $toolInput.path }
    if ($toolInput.filePath) { return $toolInput.filePath }
    if ($toolInput.file_path) { return $toolInput.file_path }
    return $null
}

# === STEP 2: Determine what to track for azmcp ===

# Azure-skills path patterns per client (used for SKILL.md and file-reference matching)
$pathPatternCopilot = '\.copilot/installed-plugins/azure-skills/azure/skills/'
$pathPatternClaude = '\.claude/plugins/cache/(azure-skills|claude-plugins-official)/azure/[0-9.]+/skills/'
$pathPatternVscodeAgentPlugins = 'agent-plugins/github\.com/microsoft/azure-skills/\.github/plugins/azure-skills/skills/'
$pathPatternAgentsSkills = '\.agents/skills/'

$shouldTrack = $false
$eventType = $null
$skillName = $null
$azureToolName = $null
$filePath = $null

# Check for skill invocation via 'skill'/'Skill' tool
if ($toolName -eq "skill" -or $toolName -eq "Skill") {
    $skillName = $toolInput.skill
    # Claude Code prefixes skill names with "azure:" (e.g., "azure:azure-prepare")
    # Strip it to get the actual skill name for the allowlist
    if ($skillName -and $skillName.StartsWith("azure:")) {
        $skillName = $skillName.Substring(6)
    }
    if ($skillName) {
        $eventType = "skill_invocation"
        $shouldTrack = $true
    }
}

# Check for skill invocation (reading SKILL.md files)
# Copilot CLI: "view", Claude Code: "Read", VS Code: "read_file"
if ($toolName -eq "view" -or $toolName -eq "Read" -or $toolName -eq "read_file") {
    $pathToCheck = Get-ToolInputPath
    if ($pathToCheck) {
        # Normalize path: convert to lowercase, replace backslashes, and squeeze consecutive slashes
        $pathLower = $pathToCheck.ToLower() -replace '\\', '/' -replace '/+', '/'

        # Check for SKILL.md pattern — only match azure-skills paths (see path patterns above)
        $isAzureSkillMd = $false
        if ($pathLower -match "${pathPatternCopilot}[^/]+/skill\.md") {
            $isAzureSkillMd = $true
        }
        elseif ($pathLower -match "${pathPatternClaude}[^/]+/skill\.md") {
            $isAzureSkillMd = $true
        }
        elseif ($pathLower -match "${pathPatternVscodeAgentPlugins}[^/]+/skill\.md") {
            $isAzureSkillMd = $true
        }
        elseif ($pathLower -match "${pathPatternAgentsSkills}[^/]+/skill\.md") {
            $isAzureSkillMd = $true
        }

        if ($isAzureSkillMd) {
            $pathNormalized = $pathToCheck -replace '\\', '/' -replace '/+', '/'
            if ($pathNormalized -match '/skills/([^/]+)/SKILL\.md$') {
                $skillName = $Matches[1]
                $eventType = "skill_invocation"
                $shouldTrack = $true
            }
        }
    }
}

# Check for Azure MCP tool invocation
# Copilot CLI:  "azure-*" prefix (e.g., azure-documentation)
# Claude Code:  "mcp__plugin_azure_azure__*" prefix (e.g., mcp__plugin_azure_azure__documentation)
# VS Code:      "mcp_azure_mcp_*" prefix (e.g., mcp_azure_mcp_documentation)
if ($toolName) {
    if ($toolName.StartsWith("azure-") -or $toolName.StartsWith("mcp__plugin_azure_azure__") -or $toolName.StartsWith("mcp_azure_mcp_")) {
        $azureToolName = $toolName
        $eventType = "tool_invocation"
        $shouldTrack = $true
    }
}

# Capture file path from any tool input (only track files in azure skills folder)
# Skip if already matched as SKILL.md skill_invocation — SKILL.md is not a valid file-reference
if (-not $filePath -and -not $skillName) {
    $pathToCheck = Get-ToolInputPath
    if ($pathToCheck) {
        # Normalize path for matching: replace backslashes and squeeze consecutive slashes
        $pathLower = $pathToCheck.ToLower() -replace '\\', '/' -replace '/+', '/'

        $matchCopilotSkills = $pathLower -match $pathPatternCopilot
        $matchClaudeSkills = $pathLower -match $pathPatternClaude
        $matchVscodeAgentPlugins = $pathLower -match $pathPatternVscodeAgentPlugins
        $matchAgentsSkills = $pathLower -match $pathPatternAgentsSkills
        if ($matchCopilotSkills -or $matchClaudeSkills -or $matchVscodeAgentPlugins -or $matchAgentsSkills) {
            # Extract relative path after 'skills/'
            $pathNormalized = $pathToCheck -replace '\\', '/' -replace '/+', '/'

            if ($pathNormalized -match '(?:azure/(?:[0-9]+\.[0-9]+\.[0-9]+/)?skills|azure-skills/skills|\.agents/skills)/(.+)$') {
                $filePath = $Matches[1]

                if (-not $shouldTrack) {
                    $shouldTrack = $true
                    $eventType = "reference_file_read"
                }
            }
        }
    }
}

# === STEP 3: Publish event ===

if ($shouldTrack) {
    # Build MCP command arguments
    $mcpArgs = @(
        "server", "plugin-telemetry",
        "--timestamp", $timestamp,
        "--client-name", $clientName
    )

    if ($eventType) { $mcpArgs += "--event-type"; $mcpArgs += $eventType }
    if ($sessionId) { $mcpArgs += "--session-id"; $mcpArgs += $sessionId }
    if ($skillName) { $mcpArgs += "--skill-name"; $mcpArgs += $skillName }
    if ($azureToolName) { $mcpArgs += "--tool-name"; $mcpArgs += $azureToolName }
    # Convert forward slashes to backslashes for azmcp allowlist compatibility
    if ($filePath) { $mcpArgs += "--file-reference"; $mcpArgs += ($filePath -replace '/', '\') }

    # Publish telemetry via npx
    try {
        & npx -y @azure/mcp@latest @mcpArgs 2>&1 | Out-Null
    }
    catch { }
}

# Output success to stdout (required by hooks)
Write-Success

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC6d+BFSFHOfP6X
# N94FbRxFR+CNyl+IQHBhQXLGgQ7my6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnlMIIZ4QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIHW6tsMd
# rizeJcYy7BZzjVnW9OCt4dyS0I/rQertgUxeMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAftTZVczRSYShyQVPTHxgguv5bD8R2sIvnn5WawLa
# C3XZrrPd04qO+JxGLOM4IWREFfe4RwteSmIet0VlJaDECEy3DhXJop7el7mJIaoA
# 3NzQxv0Ugbzli2t1ZLQhuFHl9yVkOKg94yeb5hNZaWhY4rDhZ4lzo7tqwX0NIOay
# jrtl1V7wqJS8UsunqqPj04C11vf1S+ezAAd/oaOKr1Hk06I+TIpILEQ0e8dKHCd5
# kTIjz5qvhgIFZRxbyRJkKZ5RoDJqG9GZoFpYq/4P6irdsIzPwXtaKOT04HNqLZAA
# zNSq/YalupWRMXp87iuZpVx7mbkB4zOqZQiXRPDjG8khMaGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBWIJbdaY+0EEnUVYJjuqz+hYGzf0AGVj09qm3T
# cFBY0wIGal9rgOvuGBMyMDI2MDgwMzE4MDQzNi45MjFaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046QTkzNS0wM0UwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAifVwIPDsS5XLQABAAAC
# JzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTQwMDRaFw0yNzA1MTcxOTQwMDRaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTkzNS0wM0Uw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDixWy1fDOSL4qj3A1pady+elID
# LwnF3UuLzJIOWwGHcEgrxxwtnyviUIDmmxylTUl1u+2rBPp2zT4BwwQhvGaJpExq
# vPLlDFlbfmSflKI86eFqofiZ7j8NTRO4l7wGg9Njm+muNauTcFW2qdfIjKE950Ok
# rm9MnMOGYy+fibNYdxTPRPq1T4MLZK3s3vdMyMEOldcOQkSKpxD6/1Gk6gOmCu2K
# gI8f0ex6vYxnKDl9W0OLSEa/6y82oIbsm+1QBifOQ47xWKTG1CmvtGr85LzA75/M
# AcUmRw5/of/qET0UFV1WulMcJrI6DASAsNCNB+6WLrotuBZAj+VMlqbn5RMZ6Q4I
# Y7JwaAiIXh7VjxrnwUOYZG8WEGhfrA98di+7LEn9AqvvEOyG+UQcjVhCCbMGXigJ
# XSApeyeWupCsD0jgQMNCxfB5BLBDWxgdY3dJBEPgxfkgTDQLBggtVv2d5CYxHKgI
# ItB4bI5eSb5jkIG2WotnFetT0legpw/Eozwf39ao6tENY21eVWIzRw/GsmvwjYQF
# 6vVrxOD0pGVsfqGF8s3VPeY7hI2TxHFMqNA0IB/a2NLY7JTxYAKAP/11EJZt7xbq
# DLMgD1YDdGEzGpQijm3nAPCL2CebP/jmu90abJ2W425yglGHTI/nCBrwSpfRCgwz
# rfFelJaCKM6+35aFfwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNLW58N4MGSG6ud7
# jWqgT92orfReMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQAqncud4PSC1teb2H6n
# Ruy7sDiKK13FXJirVB4Tfwjdo2Mb+QL4j7wZ/k4G9P0CANHZFrDQcK0VFDTysrYu
# 8Z0Aha14acDZPsyIoPvAGRRhaHEuf7NckRjkfa/ylo1KyII8jbL9N9sJAqBPL8V4
# FNBjljv+1GHDOw127rZz5ZSTPoAPb2SA0v5yDgcpUMfxglPyp6cnPPoQpTtD9OGx
# 8Dwm2P+o1TPxBIy6I0T9RauulogVCvKwflfeLTcKAvnSG1rCjerSXmU1DNXOsAD/
# bsrSjgbX5mAbD7XTRMF/vawAWESFcn/BjjizxeWZb00aYSlkJA2rVtFlMM481aVW
# XdAbXPP5RzUiWTlgyHf/G7lCxHYWGIZuB13T3aI6Y8mEgn/ou40aiFJo8r0+i0P5
# GdNneWtxiR0CMKUfko+5s/73cwe1Wfp8BKXa270cicVQasFf5sRV7pFm+V7fNRXw
# Cu7anTOmga76zO7/2t+zOlibvphT+Q6Zd+B2qYsSn4xBaY+YzHpnycLW5cvJyhPx
# BCcb1oRYfhRzCADb2utI2EtGCjc2P2ii4LyR4QMb/n8cOweL9IqVTKKzzVk+zZJx
# V3vrp4LyuQXw0O30la6BcHdNAAAB9UC83zs3G9d+AlIfZLM97tMUNKWjbBpIirFx
# 6LTDFXVtZQd7hqzLYByjbjH0ujCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
# AAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVow
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX
# 9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1q
# UoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8d
# q6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byN
# pOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2k
# rnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4d
# Pf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgS
# Uei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8
# QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6Cm
# gyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzF
# ER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQID
# AQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQU
# KqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1
# GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0
# bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbL
# j+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1p
# Y3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwU
# tj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN
# 3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU
# 5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5
# KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGy
# qVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB6
# 2FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltE
# AY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFp
# AUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcd
# FYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRb
# atGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQd
# VTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE5MzUtMDNFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQAjHzqthPwO0GDckDMA6x54lIiMKqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7hsLqjAiGA8y
# MDI2MDgwMzEyNDQyNloYDzIwMjYwODA0MTI0NDI2WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDuGwuqAgEAMAoCAQACAg6QAgH/MAcCAQACAhOKMAoCBQDuHF0qAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAAi6ecg0rv+XS/JDSfx0EwNvrI9H
# 5Ur6ugU5Cg+Jtf0Z4w+8zpCSxNm+Qkc0RWQbg4AEfcBAlUS+sTl8OwheLUrQ6wg7
# IXHQq/Gq0PYg0sxkZpLeCqJwwdqsMyrPccenbNs12CGFVJYvfES5tErJRSLMGnEw
# kwiLaw5Tt0xn+sIN2dxKIFCCiZOrp28thHUiJ50Q7yJH9oX6P7lKsSXYOY0PPp8s
# bRH5eZeKA5Dxpbfki2I39QfOEbpD1cKI0CaBfqoRZD4z+X2FuYFq9rVXnYlEXl0n
# irPqVdR/VQPFLGtv/Vl6Ecbc7hEKSvr4A7LoWaSWT2aODpEG+aO28Qex0FsxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAifV
# wIPDsS5XLQABAAACJzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAtPzNMERUePZV1cTWHCx0UTLq4
# Ro91iD3jd71UcjtvfzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIOXnARo1
# oVIcOLJKDqlE0adq/jZ9TXdlnXWRcXGThBFyMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIn1cCDw7EuVy0AAQAAAicwIgQg6guRmZyB
# OFoVB8HUjS5lofG5C9G1Rp1Tz/t355fqzG0wDQYJKoZIhvcNAQELBQAEggIAFR6J
# sT5f7l5+KLCoLhD0axC8Y7ijEZqnwPmxPQvPohVVcqqEKSDglfLpj7chmPCESCPB
# WA6sNT7ua1g5eayyVwkZ25X06AfNN0ry+URZ1la8Y0Ii8rx+IHaIEM2qsro2vwq1
# bA9TVYMdTl2v5lqgLPiuDg8iTLquenZDCRFPztdc8qTtesFtg9d/cyHXQiyHcayK
# G2MeAgTgFaNlQl+gdhCNiwo7Ww8OKUs9G8nkelp5isc7hKci2q3yG1KZ2dv4fR32
# rAy9oKz1uIA0JX58ITLd4yahmPgigQ/8KNsEPolorpXTybDhidmkBgdDC+wDMSKS
# D32UZyCRr37zuReewJYbvWC2v7VPX/5MLksWbU6O8udeAxL9GFJplhOFynQQ6JG+
# FzyiyFOk2Pd74wkbXYof2G1POL8gn2McB3JupRKAIvG698+6E1QHcSf5yBCG6RZw
# V0rcJ0+Wu1S5mLD/LbndcIyICSJxJUf1+8wCEUR5rym+rsMNASPbD73qkkobHOBm
# kStCR0HF6ExAvnqF3/5/URlmmbYPtTMMpb/x1G32+P8TwFYluBT6ZA+qIdpJykao
# 47CDMkVmw1SGVD4pR1ibRb2ZD9PqGwOXpdJK5gYDv30wYj4TZxAosldyVYsFMw4d
# gX5AEZfWBhwPq/QjtyLTjrDEhPGY6g5crqtvIvA=
# SIG # End signature block
