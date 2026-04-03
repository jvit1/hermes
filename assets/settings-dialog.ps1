param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,
    [Parameter(Mandatory = $true)]
    [string]$ModelPath,
    [Parameter(Mandatory = $true)]
    [string]$WhisperCliPath,
    [Parameter(Mandatory = $true)]
    [string]$Backend,
    [Parameter(Mandatory = $true)]
    [string]$Language,
    [Parameter(Mandatory = $true)]
    [string]$HotkeyModifier,
    [Parameter(Mandatory = $true)]
    [string]$HotkeyKey,
    [Parameter(Mandatory = $true)]
    [UInt64]$MinRecordMs,
    [Parameter(Mandatory = $true)]
    [UInt32]$GpuLayers,
    [Parameter(Mandatory = $true)]
    [string]$AutoPunctuation,
    [Parameter(Mandatory = $true)]
    [string]$TypeOutput
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Hermes Settings"
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(680, 560)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true

$labelWidth = 170
$inputLeft = 185
$inputWidth = 470
$rowHeight = 32
$rowY = 16

function Escape-TomlString {
    param([string]$Value)
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Add-TextField {
    param(
        [string]$FieldLabel,
        [string]$Value
    )

    $labelControl = New-Object System.Windows.Forms.Label
    $labelControl.Text = $FieldLabel
    $labelControl.AutoSize = $false
    $labelControl.Location = New-Object System.Drawing.Point(10, ($script:rowY + 6))
    $labelControl.Size = New-Object System.Drawing.Size($script:labelWidth, 20)
    $form.Controls.Add($labelControl)

    $textbox = New-Object System.Windows.Forms.TextBox
    $textbox.Location = New-Object System.Drawing.Point($script:inputLeft, ($script:rowY + 3))
    $textbox.Size = New-Object System.Drawing.Size($script:inputWidth, 23)
    $textbox.Text = $Value
    $form.Controls.Add($textbox)

    $script:rowY += $script:rowHeight
    return $textbox
}

function Add-ComboField {
    param(
        [string]$FieldLabel,
        [string[]]$Options,
        [string]$SelectedValue
    )

    $labelControl = New-Object System.Windows.Forms.Label
    $labelControl.Text = $FieldLabel
    $labelControl.AutoSize = $false
    $labelControl.Location = New-Object System.Drawing.Point(10, ($script:rowY + 6))
    $labelControl.Size = New-Object System.Drawing.Size($script:labelWidth, 20)
    $form.Controls.Add($labelControl)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = New-Object System.Drawing.Point($script:inputLeft, ($script:rowY + 3))
    $combo.Size = New-Object System.Drawing.Size($script:inputWidth, 23)
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($option in $Options) {
        $null = $combo.Items.Add($option)
    }
    $index = $combo.Items.IndexOf($SelectedValue)
    if ($index -lt 0) {
        $index = 0
    }
    $combo.SelectedIndex = $index
    $form.Controls.Add($combo)

    $script:rowY += $script:rowHeight
    return $combo
}

function Add-ActionButton {
    param(
        [string]$FieldLabel,
        [string]$ButtonText
    )

    $labelControl = New-Object System.Windows.Forms.Label
    $labelControl.Text = $FieldLabel
    $labelControl.AutoSize = $false
    $labelControl.Location = New-Object System.Drawing.Point(10, ($script:rowY + 6))
    $labelControl.Size = New-Object System.Drawing.Size($script:labelWidth, 20)
    $form.Controls.Add($labelControl)

    $button = New-Object System.Windows.Forms.Button
    $button.Location = New-Object System.Drawing.Point($script:inputLeft, ($script:rowY + 2))
    $button.Size = New-Object System.Drawing.Size(150, 24)
    $button.Text = $ButtonText
    $form.Controls.Add($button)

    $script:rowY += $script:rowHeight
    return $button
}

function Add-CheckField {
    param(
        [string]$FieldLabel,
        [bool]$Checked
    )

    $labelControl = New-Object System.Windows.Forms.Label
    $labelControl.Text = $FieldLabel
    $labelControl.AutoSize = $false
    $labelControl.Location = New-Object System.Drawing.Point(10, ($script:rowY + 6))
    $labelControl.Size = New-Object System.Drawing.Size($script:labelWidth, 20)
    $form.Controls.Add($labelControl)

    $checkbox = New-Object System.Windows.Forms.CheckBox
    $checkbox.Location = New-Object System.Drawing.Point($script:inputLeft, ($script:rowY + 6))
    $checkbox.Size = New-Object System.Drawing.Size($script:inputWidth, 20)
    $checkbox.Checked = $Checked
    $form.Controls.Add($checkbox)

    $script:rowY += $script:rowHeight
    return $checkbox
}

function Get-ModelFilename {
    param([string]$Variant)

    switch ($Variant) {
        "tiny.en" { return "ggml-tiny.en.bin" }
        "base.en" { return "ggml-base.en.bin" }
        "small.en" { return "ggml-small.en.bin" }
        "medium.en" { return "ggml-medium.en.bin" }
        "large-v3" { return "ggml-large-v3.bin" }
        default { throw "Unknown model variant: $Variant" }
    }
}

function Get-DefaultModelsDirectory {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw "LOCALAPPDATA is not set."
    }

    return Join-Path $env:LOCALAPPDATA "Hermes\Hermes\data\models"
}

function Resolve-ToolingScriptPath {
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $candidates += (Join-Path $RepoRoot "scripts\ptt_tooling.py")
    }

    if ($PSCommandPath) {
        $scriptDir = Split-Path $PSCommandPath -Parent
        $candidates += (Join-Path $scriptDir "scripts\ptt_tooling.py")
        $candidates += (Join-Path $scriptDir "..\scripts\ptt_tooling.py")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "Could not find scripts\ptt_tooling.py. Keep the scripts folder next to the app or run the app from the repository root."
}

function New-LocalToolingScriptCopy {
    param([string]$SourcePath)

    $tempPath = Join-Path $env:TEMP "hermes-tooling.py"
    Copy-Item -LiteralPath $SourcePath -Destination $tempPath -Force
    return $tempPath
}

function Resolve-PythonCommand {
    $candidates = @(
        @{ File = "py"; Args = @("-3") },
        @{ File = "python"; Args = @() }
    )

    foreach ($candidate in $candidates) {
        if (Get-Command $candidate.File -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }

    throw "Python 3 was not found. Install Python and make sure `py` or `python` is on PATH."
}

$modelPathBox = Add-TextField "Model Path" $ModelPath
$whisperCliPathBox = Add-TextField "Whisper CLI Path" $WhisperCliPath
$backendCombo = Add-ComboField "Backend Preference" @("gpu_then_cpu", "cpu_only") $Backend
$languageBox = Add-TextField "Language" $Language
$hotkeyModifierBox = Add-TextField "Hotkey Modifier" $HotkeyModifier
$hotkeyKeyBox = Add-TextField "Hotkey Key" $HotkeyKey
$modelVariantCombo = Add-ComboField "Download Model" @("tiny.en", "base.en", "small.en", "medium.en", "large-v3") "medium.en"
$downloadModelButton = Add-ActionButton "Model Download" "Download Selected Model"
$minRecordMsBox = Add-TextField "Min Record (ms)" $MinRecordMs.ToString()
$gpuLayersBox = Add-TextField "GPU Layers" $GpuLayers.ToString()
$autoPunctuationBox = Add-CheckField "Auto Punctuation" ($AutoPunctuation.ToLowerInvariant() -eq "true")
$typeOutputBox = Add-CheckField "Type Output" ($TypeOutput.ToLowerInvariant() -eq "true")

$note = New-Object System.Windows.Forms.Label
$note.Text = "Changes are saved to config.toml. You can also download a model here before saving."
$note.AutoSize = $false
$note.Location = New-Object System.Drawing.Point(10, ($rowY + 4))
$note.Size = New-Object System.Drawing.Size(650, 30)
$form.Controls.Add($note)

$buttonTop = $rowY + 44

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save"
$saveButton.Location = New-Object System.Drawing.Point(470, $buttonTop)
$saveButton.Size = New-Object System.Drawing.Size(90, 30)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "Cancel"
$cancelButton.Location = New-Object System.Drawing.Point(570, $buttonTop)
$cancelButton.Size = New-Object System.Drawing.Size(90, 30)
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

$form.AcceptButton = $saveButton
$form.CancelButton = $cancelButton

$downloadModelButton.Add_Click({
    try {
        $variant = $modelVariantCombo.SelectedItem.ToString()
        $filename = Get-ModelFilename $variant

        $targetDirectory = $null
        $existingModelPath = $modelPathBox.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($existingModelPath)) {
            try {
                $targetDirectory = Split-Path $existingModelPath -Parent
            } catch {
                $targetDirectory = $null
            }
        }
        if ([string]::IsNullOrWhiteSpace($targetDirectory)) {
            $targetDirectory = Get-DefaultModelsDirectory
        }

        $null = New-Item -ItemType Directory -Path $targetDirectory -Force
        $outputPath = Join-Path $targetDirectory $filename
        $toolingScript = Resolve-ToolingScriptPath
        $localToolingScript = New-LocalToolingScriptCopy $toolingScript
        $pythonCommand = Resolve-PythonCommand

        $arguments = @()
        $arguments += $pythonCommand.Args
        $arguments += @(
            $localToolingScript,
            "download-model",
            "--variant", $variant,
            "--output", $outputPath
        )

        $downloadModelButton.Enabled = $false
        $saveButton.Enabled = $false
        $downloadModelButton.Text = "Downloading..."
        $form.UseWaitCursor = $true
        $form.Refresh()

        try {
            $result = & $pythonCommand.File @arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw (($result | Out-String).Trim())
            }

            $modelPathBox.Text = $outputPath
            [System.Windows.Forms.MessageBox]::Show(
                "Model downloaded successfully to:`n$outputPath",
                "Hermes Settings"
            )
        } finally {
            if ($localToolingScript -and (Test-Path $localToolingScript)) {
                Remove-Item -LiteralPath $localToolingScript -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Model download failed:`n$($_.Exception.Message)",
            "Hermes Settings"
        )
    } finally {
        $downloadModelButton.Enabled = $true
        $saveButton.Enabled = $true
        $downloadModelButton.Text = "Download Selected Model"
        $form.UseWaitCursor = $false
        $form.Refresh()
    }
})

$saveButton.Add_Click({
    $modelPath = $modelPathBox.Text.Trim()
    $whisperCliPath = $whisperCliPathBox.Text.Trim()
    $language = $languageBox.Text.Trim()
    $hotkeyModifier = $hotkeyModifierBox.Text.Trim()
    $hotkeyKey = $hotkeyKeyBox.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($modelPath)) {
        [System.Windows.Forms.MessageBox]::Show("Model path cannot be empty.", "Hermes Settings")
        return
    }
    if ([string]::IsNullOrWhiteSpace($whisperCliPath)) {
        [System.Windows.Forms.MessageBox]::Show("Whisper CLI path cannot be empty.", "Hermes Settings")
        return
    }
    if ([string]::IsNullOrWhiteSpace($language)) {
        [System.Windows.Forms.MessageBox]::Show("Language cannot be empty.", "Hermes Settings")
        return
    }
    if ([string]::IsNullOrWhiteSpace($hotkeyKey)) {
        [System.Windows.Forms.MessageBox]::Show("Hotkey key cannot be empty.", "Hermes Settings")
        return
    }

    $minRecordMs = 0
    if (-not [uint64]::TryParse($minRecordMsBox.Text.Trim(), [ref]$minRecordMs)) {
        [System.Windows.Forms.MessageBox]::Show("Min Record (ms) must be a non-negative integer.", "Hermes Settings")
        return
    }

    $gpuLayers = 0
    if (-not [uint32]::TryParse($gpuLayersBox.Text.Trim(), [ref]$gpuLayers)) {
        [System.Windows.Forms.MessageBox]::Show("GPU Layers must be a non-negative integer.", "Hermes Settings")
        return
    }

    $autoPunctuationValue = if ($autoPunctuationBox.Checked) { "true" } else { "false" }
    $typeOutputValue = if ($typeOutputBox.Checked) { "true" } else { "false" }

    $tomlLines = @(
        "backend = `"$($backendCombo.SelectedItem.ToString())`"",
        "model_path = `"$($(Escape-TomlString $modelPath))`"",
        "whisper_cli_path = `"$($(Escape-TomlString $whisperCliPath))`"",
        "gpu_layers = $gpuLayers",
        "min_record_ms = $minRecordMs",
        "auto_punctuation = $autoPunctuationValue",
        "type_output = $typeOutputValue",
        "language = `"$($(Escape-TomlString $language))`"",
        "",
        "[hotkey]",
        "modifier = `"$($(Escape-TomlString $hotkeyModifier))`"",
        "key = `"$($(Escape-TomlString $hotkeyKey))`""
    )

    $form.Tag = ($tomlLines -join "`n")
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

$form.Controls.Add($saveButton)
$form.Controls.Add($cancelButton)

$null = $form.ShowDialog()
if ($form.DialogResult -eq [System.Windows.Forms.DialogResult]::OK -and $form.Tag) {
    Write-Output $form.Tag
}
