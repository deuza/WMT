<#
.SYNOPSIS
WSL2 Management Tool (WMT) - A tool for cloning, exporting, and importing WSL2 distributions,
with advanced ZIP compression management integrated into the export form.

.AUTHOR
DeuZa
#>

#region Initial Configuration
$LOG_FILE = Join-Path -Path $PSScriptRoot -ChildPath "wmt_wsl.log" 
$MIN_DISK_SPACE = 12GB # 12 GB minimum disk space
$env:WSL_UTF8 = 1 # Request WSL to output in UTF-8

# Load UI Assemblies
try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue # For ZipFile
} catch {
    Write-Host "ERROR: Failed to load UI components or IO.Compression: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
#endregion

#region Auxiliary Functions (Log, MessageBox, InputBox, DiskSpace, WslDetails, ClearFailedImport)
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","DEBUG")][string]$Level="INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp][$Level] $Message"
    try {
        Add-Content -Path $LOG_FILE -Value $logEntry -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host "LOG ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    $color = switch ($Level) {
        "SUCCESS" {"Green"}
        "WARN"    {"Yellow"}
        "ERROR"   {"Red"}
        "DEBUG"   {"Cyan"}
        default   {"White"}
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Show-MessageBoxWrapper {
    param(
        [string]$Text,
        [string]$Caption,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )
    return [System.Windows.Forms.MessageBox]::Show($Text, $Caption, $Buttons, $Icon)
}

function Show-InputBoxWrapper {
    param([string]$Prompt, [string]$Title, [string]$DefaultText = "")
    return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $DefaultText)
}

function Test-DiskSpace {
    param([string]$PathToCheck, [int64]$RequiredSpace)
    Write-Log "Checking disk space for path '$PathToCheck' (Required: $([math]::Round($RequiredSpace/1GB,2)) GB)..." -Level DEBUG
    try {
        $effectivePath = $PathToCheck
        if (-not (Test-Path -Path $PathToCheck -PathType Container)) {
            $effectivePath = Split-Path -Path $PathToCheck -Parent
            if (-not $effectivePath -and (Split-Path $PathToCheck -IsAbsolute)) { $effectivePath = Split-Path -Path $PathToCheck -Qualifier }
            elseif (-not $effectivePath) { $effectivePath = $PSScriptRoot; Write-Log "Path '$PathToCheck' has no explicit parent, checking on '$effectivePath'." -Level WARN }
        }
        $driveLetter = (Get-Item -Path $effectivePath).PSDrive.Name
        if (-not $driveLetter) {
            $pathRoot = Split-Path -Path (Resolve-Path $effectivePath).ProviderPath -Qualifier
            if ($pathRoot -and $pathRoot.Contains(":")) { $driveLetter = $pathRoot.Substring(0,1) } else { throw "Cannot determine drive letter for '$effectivePath'." }
        }
        $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
        if ($volume.SizeRemaining -lt $RequiredSpace) {
            Write-Log "Insufficient disk space on drive $driveLetter`: $([math]::Round($volume.SizeRemaining/1GB,2)) GB remaining < $([math]::Round($RequiredSpace/1GB,2)) GB required." -Level ERROR
            $null = Show-MessageBoxWrapper -Text "Insufficient disk space on drive $driveLetter`:.`nRequired: $([math]::Round($RequiredSpace/1GB,2)) GB.`nAvailable: $([math]::Round($volume.SizeRemaining/1GB,2)) GB." -Caption "Insufficient Disk Space" -Icon Error
            return $false
        }
        Write-Log "Disk space OK on drive $driveLetter`: $([math]::Round($volume.SizeRemaining/1GB,2)) GB available." -Level INFO; return $true
    } catch {
        Write-Log "Could not check disk space for '$PathToCheck': $($_.Exception.Message)." -Level WARN
        $result = Show-MessageBoxWrapper -Text "Warning: Could not check disk space for '$PathToCheck'.`nError: $($_.Exception.Message)`n`nDo you want to continue anyway?" -Caption "Disk Space Check" -Buttons YesNo -Icon Warning
        return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
    }
}

function Get-WslDistroDetails {
    param([string]$DistroName)
    Write-Log "Fetching details for distribution '$DistroName'..." -Level DEBUG
    try {
        $originalConsoleEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $verboseOutputLines = wsl.exe --list --verbose; [Console]::OutputEncoding = $originalConsoleEncoding
        if ($LASTEXITCODE -ne 0) { Write-Log "'wsl -l -v' command failed." -L WARN; return @{Name=$DistroName;State="Error";Version="N/A";IsDefault=$false;InstallDate="N/A"} }
        foreach ($line in ($verboseOutputLines | Select-Object -Skip 1)) { 
            if ($line -match "^\s*(\*?)\s*(.+?)\s\s+([A-Za-z]+)\s+([0-9]+)\s*$") {
                 $isDefaultMarker=$matches[1].Trim(); $currentDistroName=$matches[2].Trim(); $state=$matches[3].Trim(); $version=$matches[4].Trim()
                 if ($currentDistroName -eq $DistroName) { Write-Log "Details for '$DistroName': State=$state, WSL_Ver=$version, Default=$([bool]($isDefaultMarker -eq '*'))" -L DEBUG; return @{Name=$currentDistroName;State=$state;Version=$version;IsDefault=$([bool]($isDefaultMarker-eq'*'));InstallDate="N/A (not provided by WSL)"}}
            }
        }
        Write-Log "No specific details found for '$DistroName' in 'wsl -l -v'." -Level WARN
    } catch { Write-Log "Error fetching WSL details for '$DistroName': $($_.Exception.Message)" -L WARN }
    return @{Name=$DistroName;State="Unknown";Version="N/A";IsDefault=$false;InstallDate="N/A"}
}

function Clear-FailedImport {
    param([string]$DistroName, [string]$InstallPath)
    Write-Log "Attempting to clean up after failed import for '$DistroName'." -L WARN
    try {
        if ((wsl.exe --list --quiet) -contains $DistroName) { Write-Log "Cleaning up partially registered distribution '$DistroName'..." -L WARN; wsl.exe --unregister $DistroName 2>&1|Out-Null; if($LASTEXITCODE -eq 0){Write-Log "'$DistroName' unregistered." -L INFO}else{Write-Log "Failed to unregister '$DistroName'." -L ERROR}}
        if (Test-Path $InstallPath -PathType Container) { Write-Log "Deleting partial installation folder '$InstallPath'..." -L WARN; Remove-Item $InstallPath -Recurse -Fo -EA SilentlyContinue; if(Test-Path $InstallPath){Write-Log "Failed to delete folder '$InstallPath'." -L ERROR}else{Write-Log "Folder '$InstallPath' deleted." -L INFO}}
    } catch { Write-Log "Exception during cleanup for '$DistroName': $($_.Exception.Message)" -L ERROR }
}
#endregion

#region Compression/Decompression Functions
function Get-7ZipPath {
    Write-Log "Searching for 7-Zip executable (7z.exe)..." -Level DEBUG
    $7zipCommand = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($7zipCommand) {
        Write-Log "7-Zip found in PATH: $($7zipCommand.Source)" -Level INFO
        return $7zipCommand.Source
    }

    $commonPaths = @()
    if (-not [string]::IsNullOrEmpty($env:ProgramFiles)) { $commonPaths += Join-Path -Path $env:ProgramFiles -ChildPath "7-Zip\7z.exe" }
    if (-not [string]::IsNullOrEmpty($env:ProgramW6432)) { $commonPaths += Join-Path -Path $env:ProgramW6432 -ChildPath "7-Zip\7z.exe" }
    if (-not [string]::IsNullOrEmpty(${env:ProgramFiles(x86)})) { $commonPaths += Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "7-Zip\7z.exe" }
    
    foreach ($path in ($commonPaths | Get-Unique)) { 
        if (Test-Path -Path $path -PathType Leaf) {
            Write-Log "7-Zip found at common path: $path" -Level INFO
            return $path
        }
    }

    Write-Log "7-Zip executable (7z.exe) not found in PATH or common locations." -Level INFO
    return $null
}

function Invoke-AdvancedCompression {
    param([Parameter(Mandatory)][string]$SourceFilePath, [Parameter(Mandatory)][string]$DestinationZipPath)
    Write-Log "Compressing '$SourceFilePath' to '$DestinationZipPath'..." -Level INFO
    $7zipExePath = Get-7ZipPath
    if ($7zipExePath) {
        Write-Log "Using 7-Zip: $7zipExePath" -Level INFO
        try {
            $arguments = "a -tzip `"$DestinationZipPath`" `"$SourceFilePath`" -y"; Write-Log "Executing 7-Zip: $arguments" -L DEBUG
            $processInfo = Start-Process -FilePath $7zipExePath -ArgumentList $arguments -Wait -NoNewWindow -PassThru
            if ($processInfo.ExitCode -eq 0) { Write-Log "7-Zip compression successful." -L SUCCESS; return $true }
            else { Write-Log "7-Zip compression failed. Exit Code: $($processInfo.ExitCode)." -L ERROR; return $false }
        } catch { Write-Log "Exception during 7-Zip compression: $($_.Exception.Message)" -L ERROR; return $false }
    } else { Write-Log "7-Zip not found. Falling back to System.IO.Compression.ZipFile." -Level INFO }
    try {
        if (Test-Path $DestinationZipPath) { Write-Log "Destination ZIP '$DestinationZipPath' exists. Deleting..." -L WARN; Remove-Item $DestinationZipPath -Force }
        $zipArchive = [System.IO.Compression.ZipFile]::Open($DestinationZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        $entryNameInZip = Split-Path -Path $SourceFilePath -Leaf
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $SourceFilePath, $entryNameInZip, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        $zipArchive.Dispose()
        Write-Log "System.IO.Compression.ZipFile compression successful." -L SUCCESS; return $true
    } catch {
        Write-Log "Exception during System.IO.Compression.ZipFile compression: $($_.Exception.Message)" -L ERROR
        if (Test-Path $DestinationZipPath) { Remove-Item $DestinationZipPath -Force -EA SilentlyContinue }
        return $false
    }
}

function Invoke-AdvancedDecompression {
    param([Parameter(Mandatory)][string]$SourceZipPath, [Parameter(Mandatory)][string]$DestinationExtractPath)
    Write-Log "Decompressing '$SourceZipPath' to '$DestinationExtractPath'..." -Level INFO
    if (-not (Test-Path $DestinationExtractPath)) { New-Item -ItemType Directory -Path $DestinationExtractPath -Force | Out-Null }
    $7zipExePath = Get-7ZipPath
    if ($7zipExePath) {
        Write-Log "Using 7-Zip for decompression." -Level INFO
        try {
            $arguments = "x `"$SourceZipPath`" -o`"$DestinationExtractPath`" -y"; Write-Log "Executing 7-Zip: $arguments" -L DEBUG
            $processInfo = Start-Process -FilePath $7zipExePath -ArgumentList $arguments -Wait -NoNewWindow -PassThru
            if ($processInfo.ExitCode -eq 0) { Write-Log "7-Zip decompression successful." -L SUCCESS; return $true }
            else { Write-Log "7-Zip decompression failed. Exit Code: $($processInfo.ExitCode)." -L ERROR; return $false }
        } catch { Write-Log "Exception during 7-Zip decompression: $($_.Exception.Message)" -L ERROR; return $false }
    } else { Write-Log "7-Zip not found. Falling back to System.IO.Compression.ZipFile." -Level INFO }
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($SourceZipPath, $DestinationExtractPath, $true) 
        Write-Log "System.IO.Compression.ZipFile decompression successful." -L SUCCESS; return $true
    } catch { Write-Log "Exception during System.IO.Compression.ZipFile decompression: $($_.Exception.Message)" -L ERROR; return $false }
}
#endregion

#region GUI Forms
function Show-MainMenuForm {
    $form = New-Object System.Windows.Forms.Form; $form.Text = "WSL2 Management Tool (WMT) v$SCRIPT_VERSION"; $form.Size = New-Object System.Drawing.Size(300, 240); $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
    $labelTitle = New-Object System.Windows.Forms.Label; $labelTitle.Text="Choose an action:"; $labelTitle.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); $labelTitle.AutoSize=$true; $labelTitle.Location=New-Object System.Drawing.Point(20,20); $form.Controls.Add($labelTitle)
    $buttonClone=New-Object System.Windows.Forms.Button; $buttonClone.Text="Clone a Distribution"; $buttonClone.Size=New-Object System.Drawing.Size(240,30); $buttonClone.Location=New-Object System.Drawing.Point(20,50); $buttonClone.DialogResult='Retry'; $form.Controls.Add($buttonClone)
    $buttonExport=New-Object System.Windows.Forms.Button; $buttonExport.Text="Export a Distribution"; $buttonExport.Size=New-Object System.Drawing.Size(240,30); $buttonExport.Location=New-Object System.Drawing.Point(20,90); $buttonExport.DialogResult='Yes'; $form.Controls.Add($buttonExport)
    $buttonImport=New-Object System.Windows.Forms.Button; $buttonImport.Text="Import a Distribution"; $buttonImport.Size=New-Object System.Drawing.Size(240,30); $buttonImport.Location=New-Object System.Drawing.Point(20,130); $buttonImport.DialogResult='No'; $form.Controls.Add($buttonImport)
    $buttonQuit=New-Object System.Windows.Forms.Button; $buttonQuit.Text="Quit"; $buttonQuit.Size=New-Object System.Drawing.Size(240,30); $buttonQuit.Location=New-Object System.Drawing.Point(20,170); $buttonQuit.DialogResult='Cancel'; $form.Controls.Add($buttonQuit); $form.CancelButton=$buttonQuit
    $result=$form.ShowDialog(); $form.Dispose()
    if($result -eq 'Retry'){return 'Clone'} if($result -eq 'Yes'){return 'Export'} if($result -eq 'No'){return 'Import'} return 'Quit'
}

function Show-SelectDistroForExportForm { 
    param([array]$availableDistros, [string]$DefaultExportDir, [string]$FormTitle = "Export WSL Distribution")
    $form = New-Object System.Windows.Forms.Form; $form.Text = $FormTitle; $form.Size = New-Object System.Drawing.Size(500,360); $form.StartPosition="CenterScreen"; $form.FormBorderStyle="FixedDialog"; $form.MaximizeBox=$false; $form.MinimizeBox=$true; $form.KeyPreview=$true
    $groupDistro=New-Object System.Windows.Forms.GroupBox; $groupDistro.Text="1. Select Source Distribution"; $groupDistro.Location=New-Object System.Drawing.Point(10,10); $groupDistro.Size=New-Object System.Drawing.Size(460,130)
    $lblDistro=New-Object System.Windows.Forms.Label; $lblDistro.Text="Distribution to export:"; $lblDistro.Location=New-Object System.Drawing.Point(10,25); $lblDistro.AutoSize=$true; $groupDistro.Controls.Add($lblDistro)
    $cbDistro=New-Object System.Windows.Forms.ComboBox; $cbDistro.Location=New-Object System.Drawing.Point(170,22); $cbDistro.Size=New-Object System.Drawing.Size(280,25); $cbDistro.DropDownStyle="DropDownList"; if($availableDistros){$availableDistros|%{$cbDistro.Items.Add($_)}|Out-Null}; $groupDistro.Controls.Add($cbDistro)
    $lblDetails=New-Object System.Windows.Forms.Label; $lblDetails.Location=New-Object System.Drawing.Point(10,55); $lblDetails.Size=New-Object System.Drawing.Size(440,65); $lblDetails.BorderStyle=[System.Windows.Forms.BorderStyle]::FixedSingle; $lblDetails.Text="Select a distribution."; $groupDistro.Controls.Add($lblDetails)
    $grpExport=New-Object System.Windows.Forms.GroupBox; $grpExport.Text="2. Specify Destination .tar File"; $grpExport.Location=New-Object System.Drawing.Point(10,150); $grpExport.Size=New-Object System.Drawing.Size(460,90)
    $lblPath=New-Object System.Windows.Forms.Label; $lblPath.Text="Destination .tar file:"; $lblPath.Location=New-Object System.Drawing.Point(10,25); $lblPath.AutoSize=$true; $grpExport.Controls.Add($lblPath)
    $txtPath=New-Object System.Windows.Forms.TextBox; $txtPath.Location=New-Object System.Drawing.Point(170,22); $txtPath.Size=New-Object System.Drawing.Size(195,25); $grpExport.Controls.Add($txtPath)
    $btnBrowse=New-Object System.Windows.Forms.Button; $btnBrowse.Text="Browse..."; $btnBrowse.Location=New-Object System.Drawing.Point(370,21); $btnBrowse.Size=New-Object System.Drawing.Size(80,27); $grpExport.Controls.Add($btnBrowse)
    $chkCompress=New-Object System.Windows.Forms.CheckBox; $chkCompress.Text="Compress to .zip after export (uses 7-Zip if available)"; $chkCompress.Location=New-Object System.Drawing.Point(10,55); $chkCompress.AutoSize=$true; $grpExport.Controls.Add($chkCompress)
    $btnOK=New-Object System.Windows.Forms.Button; $btnOK.Text="OK"; $btnOK.Location=New-Object System.Drawing.Point(280,255); $btnOK.Size=New-Object System.Drawing.Size(90,30); $btnOK.DialogResult='OK'
    $btnCancel=New-Object System.Windows.Forms.Button; $btnCancel.Text="Cancel"; $btnCancel.Location=New-Object System.Drawing.Point(380,255); $btnCancel.Size=New-Object System.Drawing.Size(90,30); $btnCancel.DialogResult='Cancel'
    $btnLog=New-Object System.Windows.Forms.Button; $btnLog.Text="View Log"; $btnLog.Location=New-Object System.Drawing.Point(10,255); $btnLog.Size=New-Object System.Drawing.Size(90,30)
    $UpdAct={if($cbDistro.SelectedItem){$s=$cbDistro.SelectedItem.ToString();$d=Get-WslDistroDetails -DistroName $s;$lblDetails.Text="Name: $($d.Name)`nState: $($d.State)`nWSL Ver: $($d.Version)`nDefault: $($d.IsDefault)";$txtPath.Text=Join-Path $DefaultExportDir "$s.tar"}else{$lblDetails.Text="Select a distribution.";$txtPath.Text=""}}
    $cbDistro.Add_SelectedIndexChanged($UpdAct); if($availableDistros -and $availableDistros.Count -gt 0){$cbDistro.SelectedIndex=0}else{$cbDistro.Enabled=$false;$btnOK.Enabled=$false;$lblDetails.Text="No distributions available."}
    $btnBrowse.Add_Click({$sfd=New-Object System.Windows.Forms.SaveFileDialog;$sfd.Filter="TAR Archive (*.tar)|*.tar";$sfd.Title="Export to";$sfd.DefaultExt="tar";if($txtPath.Text){try{$sfd.FileName=(Split-Path $txtPath.Text -Leaf);$sfd.InitialDirectory=(Split-Path $txtPath.Text -Parent)}catch{}}else{$sfd.InitialDirectory=$DefaultExportDir};if($sfd.ShowDialog($form)-eq 'OK'){$txtPath.Text=$sfd.FileName}})
    $btnLog.Add_Click({if(Test-Path $LOG_FILE){try{Start-Process notepad.exe $LOG_FILE -EA Stop}catch{Write-Log "Error opening log: $($_.Exception.Message)" -L WARN}}else{$null=Show-MessageBoxWrapper -T "Log file '$LOG_FILE' not found." -C "Log Not Found" -I Information}})
    $form.Add_KeyDown({if($_.KeyCode -eq 'Escape') {$form.Close()}}); $form.Controls.AddRange(@($groupDistro,$grpExport,$btnOK,$btnCancel,$btnLog)); $form.AcceptButton=$btnOK; $form.CancelButton=$btnCancel
    $diagRes=$form.ShowDialog(); $retData=$null
    if($diagRes -eq 'OK'){
        if([string]::IsNullOrWhiteSpace($cbDistro.SelectedItem)){$null=Show-MessageBoxWrapper -T "No distribution selected." -C "Selection Error" -I Error}
        elseif([string]::IsNullOrWhiteSpace($txtPath.Text)-or -not ($txtPath.Text.ToLower().EndsWith(".tar"))){$null=Show-MessageBoxWrapper -T "Invalid export path (must be .tar)." -C "Path Error" -I Error}
        else{$retData=@{SelectedDistro=$cbDistro.SelectedItem.ToString(); ExportPath=$txtPath.Text; Compress=$chkCompress.Checked; DialogResult=$diagRes}}
    } else {$retData=@{DialogResult=$diagRes}}
    $form.Dispose(); return $retData
}

function Show-GetImportDetailsForm { 
    param ([array]$existingDistrosList)
    $form = New-Object System.Windows.Forms.Form; $form.Text = "Import WSL Distribution"; $form.Size = New-Object System.Drawing.Size(520,230); $form.StartPosition="CenterScreen"; $form.FormBorderStyle="FixedDialog"; $form.MaximizeBox=$false; $form.MinimizeBox=$false; $form.KeyPreview=$true
    $lblTar=New-Object System.Windows.Forms.Label; $lblTar.Text="Source file (.tar or .zip):"; $lblTar.Location=New-Object System.Drawing.Point(10,25); $lblTar.AutoSize=$true
    $txtTar=New-Object System.Windows.Forms.TextBox; $txtTar.Location=New-Object System.Drawing.Point(190,22); $txtTar.Size=New-Object System.Drawing.Size(225,25) 
    $btnBrowseTar=New-Object System.Windows.Forms.Button; $btnBrowseTar.Text="Browse..."; $btnBrowseTar.Location=New-Object System.Drawing.Point(420,21); $btnBrowseTar.Size=New-Object System.Drawing.Size(80,27)
    $lblNewName=New-Object System.Windows.Forms.Label; $lblNewName.Text="Name for new distribution:"; $lblNewName.Location=New-Object System.Drawing.Point(10,60); $lblNewName.AutoSize=$true
    $txtNewName=New-Object System.Windows.Forms.TextBox; $txtNewName.Location=New-Object System.Drawing.Point(190,57); $txtNewName.Size=New-Object System.Drawing.Size(310,25)
    $lblInstallDir=New-Object System.Windows.Forms.Label; $lblInstallDir.Text="Installation directory:"; $lblInstallDir.Location=New-Object System.Drawing.Point(10,95); $lblInstallDir.AutoSize=$true
    $txtInstallDir=New-Object System.Windows.Forms.TextBox; $txtInstallDir.Location=New-Object System.Drawing.Point(190,92); $txtInstallDir.Size=New-Object System.Drawing.Size(225,25) 
    $btnBrowseDir=New-Object System.Windows.Forms.Button; $btnBrowseDir.Text="Browse..."; $btnBrowseDir.Location=New-Object System.Drawing.Point(420,91); $btnBrowseDir.Size=New-Object System.Drawing.Size(80,27)
    $btnOK=New-Object System.Windows.Forms.Button; $btnOK.Text="Import"; $btnOK.Location=New-Object System.Drawing.Point(300,145); $btnOK.Size=New-Object System.Drawing.Size(90,30); $btnOK.DialogResult='OK'
    $btnCancel=New-Object System.Windows.Forms.Button; $btnCancel.Text="Cancel"; $btnCancel.Location=New-Object System.Drawing.Point(400,145); $btnCancel.Size=New-Object System.Drawing.Size(90,30); $btnCancel.DialogResult='Cancel'
    $form.Controls.AddRange(@($lblTar,$txtTar,$btnBrowseTar,$lblNewName,$txtNewName,$lblInstallDir,$txtInstallDir,$btnBrowseDir,$btnOK,$btnCancel)); $form.AcceptButton=$btnOK; $form.CancelButton=$btnCancel
    $btnBrowseTar.Add_Click({$ofd=New-Object System.Windows.Forms.OpenFileDialog;$ofd.Filter="WSL Archives (*.tar;*.zip)|*.tar;*.zip|TAR Archive (*.tar)|*.tar|ZIP Archive (*.zip)|*.zip";$ofd.Title="Select Archive";if($ofd.ShowDialog($form)-eq 'OK'){$txtTar.Text=$ofd.FileName}})
    $btnBrowseDir.Add_Click({$fbd=New-Object System.Windows.Forms.FolderBrowserDialog;$fbd.Description="Select installation folder";if($fbd.ShowDialog($form)-eq 'OK'){$txtInstallDir.Text=$fbd.SelectedPath}})
    $form.Add_KeyDown({if($_.KeyCode-eq 'Escape'){$form.Close()}}); $diagRes=$form.ShowDialog(); $retData=$null
    if($diagRes -eq 'OK'){if(-not(Test-Path $txtTar.Text -PathType Leaf)){$null=Show-MessageBoxWrapper -T "Invalid source file." -C "File Error" -I Error}elseif([string]::IsNullOrWhiteSpace($txtNewName.Text)){$null=Show-MessageBoxWrapper -T "New distribution name required." -C "Name Error" -I Error}elseif($existingDistrosList -contains $txtNewName.Text.Trim()){$null=Show-MessageBoxWrapper -T "Distribution name '$($txtNewName.Text.Trim())' already exists." -C "Name Conflict" -I Error}elseif([string]::IsNullOrWhiteSpace($txtInstallDir.Text)){$null=Show-MessageBoxWrapper -T "Installation directory required." -C "Directory Error" -I Error}else{$retData=@{SourceArchivePath=$txtTar.Text;NewDistroName=$txtNewName.Text.Trim();InstallPath=$txtInstallDir.Text;DialogResult=$diagRes}}}else{$retData=@{DialogResult=$diagRes}}
    $form.Dispose(); return $retData
}
function Show-GetCloneDetailsForm { 
    param ([string]$OriginalDistroName, [array]$existingDistrosList)
    $form = New-Object System.Windows.Forms.Form; $form.Text = "Clone '$OriginalDistroName'"; $form.Size = New-Object System.Drawing.Size(500,190); $form.StartPosition="CenterScreen"; $form.FormBorderStyle="FixedDialog"; $form.MaximizeBox=$false; $form.KeyPreview=$true
    $lblNewName=New-Object System.Windows.Forms.Label; $lblNewName.Text="Name for the clone:"; $lblNewName.Location=New-Object System.Drawing.Point(10,25); $lblNewName.AutoSize=$true
    $txtNewName=New-Object System.Windows.Forms.TextBox; $txtNewName.Location=New-Object System.Drawing.Point(190,22); $txtNewName.Size=New-Object System.Drawing.Size(290,25); $txtNewName.Text = "$OriginalDistroName-clone"
    $lblInstallDir=New-Object System.Windows.Forms.Label; $lblInstallDir.Text="Clone installation directory:"; $lblInstallDir.Location=New-Object System.Drawing.Point(10,60); $lblInstallDir.AutoSize=$true
    $txtInstallDir=New-Object System.Windows.Forms.TextBox; $txtInstallDir.Location=New-Object System.Drawing.Point(190,57); $txtInstallDir.Size=New-Object System.Drawing.Size(225,25); $txtInstallDir.Text = (Join-Path ($env:USERPROFILE + "\WSL_Distros") "$($txtNewName.Text)")
    $btnBrowseDir=New-Object System.Windows.Forms.Button; $btnBrowseDir.Text="Browse..."; $btnBrowseDir.Location=New-Object System.Drawing.Point(420,56); $btnBrowseDir.Size=New-Object System.Drawing.Size(70,27) 
    $btnOK=New-Object System.Windows.Forms.Button; $btnOK.Text="Clone"; $btnOK.Location=New-Object System.Drawing.Point(280,105); $btnOK.Size=New-Object System.Drawing.Size(90,30); $btnOK.DialogResult='OK'
    $btnCancel=New-Object System.Windows.Forms.Button; $btnCancel.Text="Cancel"; $btnCancel.Location=New-Object System.Drawing.Point(380,105); $btnCancel.Size=New-Object System.Drawing.Size(90,30); $btnCancel.DialogResult='Cancel'
    $form.Controls.AddRange(@($lblNewName,$txtNewName,$lblInstallDir,$txtInstallDir,$btnBrowseDir,$btnOK,$btnCancel)); $form.AcceptButton=$btnOK; $form.CancelButton=$btnCancel
    $btnBrowseDir.Add_Click({$fbd=New-Object System.Windows.Forms.FolderBrowserDialog;$fbd.Description="Select clone installation folder";if($fbd.ShowDialog($form)-eq 'OK'){$txtInstallDir.Text=$fbd.SelectedPath}})
    $txtNewName.Add_TextChanged({ $txtInstallDir.Text = (Join-Path ($env:USERPROFILE + "\WSL_Distros") "$($txtNewName.Text)") })
    $form.Add_KeyDown({if($_.KeyCode-eq 'Escape'){$form.Close()}}); $diagRes=$form.ShowDialog(); $retData=$null
    if($diagRes -eq 'OK'){if([string]::IsNullOrWhiteSpace($txtNewName.Text)){$null=Show-MessageBoxWrapper -T "Clone name required." -C "Name Error" -I Error}elseif($existingDistrosList -contains $txtNewName.Text.Trim()){$null=Show-MessageBoxWrapper -T "Name '$($txtNewName.Text.Trim())' already exists." -C "Name Conflict" -I Error}elseif([string]::IsNullOrWhiteSpace($txtInstallDir.Text)){$null=Show-MessageBoxWrapper -T "Installation directory required." -C "Directory Error" -I Error}else{$retData=@{NewCloneName=$txtNewName.Text.Trim();InstallPath=$txtInstallDir.Text;DialogResult=$diagRes}}}else{$retData=@{DialogResult=$diagRes}}
    $form.Dispose(); return $retData
}
#endregion

#region WSL Operations (Export-WslDistribution, Import-WslDistribution)
function Export-WslDistribution {
    param([string]$DistroNameToExport, [string]$PathToExportTo)
    if (-not (Test-DiskSpace -PathToCheck $PathToExportTo -RequiredSpace $MIN_DISK_SPACE)) { throw "Insufficient disk space to export to '$PathToExportTo'." }
    Write-Log "Starting export of '$DistroNameToExport' to '$PathToExportTo'." -Level INFO
    $null = Show-MessageBoxWrapper -Text "Exporting '$DistroNameToExport' to '$PathToExportTo' will now begin.`nPlease wait..." -Caption "Export in Progress" -Icon Information
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $wslExitCode = -1; $wslOutput = ""
    try {
        $scriptBlock = { param($D,$E) [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $c=wsl.exe --export $D $E 2>&1; return [PSCustomObject]@{O=$c;EC=$LASTEXITCODE} }
        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $DistroNameToExport, $PathToExportTo
        Write-Log "Export job started for '$DistroNameToExport'." -Level DEBUG
        Write-Host -NoNewline ("Exporting... Time elapsed: " + $Stopwatch.Elapsed.ToString('hh\:mm\:ss'))
        while ($job.State -eq 'Running') { Write-Host -NoNewline ("`rExporting... Time elapsed: " + $Stopwatch.Elapsed.ToString('hh\:mm\:ss') + "  "); Start-Sleep -Milliseconds 200 }
        Write-Host ""; $jobResult = Receive-Job $job -Wait -AutoRemoveJob; $Stopwatch.Stop()
        if ($jobResult) { $wslOutput = $jobResult.O; $wslExitCode = $jobResult.EC } else { throw "Export job did not return a valid result." }
        $elapsedTime = $Stopwatch.Elapsed.ToString('hh\:mm\:ss')
        if ($wslExitCode -ne 0) { throw "wsl --export command failed. Exit Code: $wslExitCode. Output: $($wslOutput -join "`n"). Duration: $elapsedTime" }
        Write-Log "Export of '$DistroNameToExport' successful in $elapsedTime." -Level SUCCESS; return $true
    } catch {
        $Stopwatch.Stop; Write-Host ""; Write-Log "Export failed: $($_.Exception.Message)" -Level ERROR
        $null = Show-MessageBoxWrapper -Text "Export of '$DistroNameToExport' failed.`nError: $($_.Exception.Message)" -Caption "Export Failed" -Icon Error
        if (Test-Path $PathToExportTo) { Write-Log "Attempting to delete partial export file: $PathToExportTo" -L WARN; Remove-Item $PathToExportTo -Fo -EA SilentlyContinue }
        return $false
    }
}

function Import-WslDistribution {
    param([string]$NewDistroName, [string]$InstallPath, [string]$TarFilePathToImport) 
    if (-not (Test-DiskSpace -PathToCheck $InstallPath -RequiredSpace $MIN_DISK_SPACE)) { throw "Insufficient disk space to import into '$InstallPath'." }
    if (-not (Test-Path -Path $InstallPath -PathType Container)) {
        Write-Log "Installation directory '$InstallPath' does not exist. Attempting to create..." -Level INFO
        try { New-Item -ItemType Directory -Path $InstallPath -Force -EA Stop | Out-Null; Write-Log "Directory '$InstallPath' created." -L SUCCESS }
        catch { throw "Could not create directory '$InstallPath'. Error: $($_.Exception.Message)" }
    }
    Write-Log "Starting import of '$TarFilePathToImport' to '$InstallPath' as '$NewDistroName'." -Level INFO
    $null = Show-MessageBoxWrapper -Text "Importing '$NewDistroName' will now begin.`nPlease wait..." -Caption "Import in Progress" -Icon Information
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $wslExitCode = -1; $wslOutput = ""
    try {
        $scriptBlock = { param($N,$I,$T) [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $c=wsl.exe --import $N $I $T --version 2 2>&1; return [PSCustomObject]@{O=$c;EC=$LASTEXITCODE} }
        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $NewDistroName, $InstallPath, $TarFilePathToImport
        Write-Log "Import job started for '$NewDistroName'." -Level DEBUG
        Write-Host -NoNewline ("Importing... Time elapsed: " + $Stopwatch.Elapsed.ToString('hh\:mm\:ss'))
        while ($job.State -eq 'Running') { Write-Host -NoNewline ("`rImporting... Time elapsed: " + $Stopwatch.Elapsed.ToString('hh\:mm\:ss') + "  "); Start-Sleep -Milliseconds 200 }
        Write-Host ""; $jobResult = Receive-Job $job -Wait -AutoRemoveJob; $Stopwatch.Stop()
        if ($jobResult) { $wslOutput = $jobResult.O; $wslExitCode = $jobResult.EC } else { throw "Import job did not return a valid result." }
        $elapsedTime = $Stopwatch.Elapsed.ToString('hh\:mm\:ss')
        if ($wslExitCode -ne 0) { throw "wsl --import command failed. Exit Code: $wslExitCode. Output: $($wslOutput -join "`n"). Duration: $elapsedTime" }
        Write-Log "Import of '$NewDistroName' successful in $elapsedTime." -Level SUCCESS; return $true
    } catch {
        $Stopwatch.Stop; Write-Host ""; Write-Log "Import failed: $($_.Exception.Message)" -Level ERROR
        $null = Show-MessageBoxWrapper -Text "Import of '$NewDistroName' failed.`nError: $($_.Exception.Message)" -Caption "Import Failed" -Icon Error
        Clear-FailedImport -DistroName $NewDistroName -InstallPath $InstallPath; return $false
    }
}
#endregion

#region Main Entry Point & Workflows
Clear-Host
Write-Log "--- Starting WSL Management Tool (WMT) v$SCRIPT_VERSION ---" -Level INFO

Write-Log "Checking WSL status via 'wsl.exe --status'..." -Level DEBUG
$wslStatusOutput = ""; $wslStatusError = ""
try {
    $psiStatus = New-Object System.Diagnostics.ProcessStartInfo; $psiStatus.FileName = "wsl.exe"; $psiStatus.Arguments = "--status"; $psiStatus.UseShellExecute = $false; $psiStatus.RedirectStandardOutput = $true; $psiStatus.RedirectStandardError = $true; $psiStatus.CreateNoWindow = $true; $psiStatus.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psiStatus.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $processStatus = New-Object System.Diagnostics.Process; $processStatus.StartInfo = $psiStatus; $processStatus.Start() | Out-Null
    $wslStatusOutput = $processStatus.StandardOutput.ReadToEnd(); $wslStatusError = $processStatus.StandardError.ReadToEnd(); $processStatus.WaitForExit()
    if ($processStatus.ExitCode -ne 0) { $errMsg="wsl --status command failed with exit code $($processStatus.ExitCode)."; if(-not [string]::IsNullOrWhiteSpace($wslStatusError)){$errMsg += "`nError: $($wslStatusError.Trim())"}elseif(-not [string]::IsNullOrWhiteSpace($wslStatusOutput)){$errMsg += "`nOutput: $($wslStatusOutput.Trim())"}; throw $errMsg }
    Write-Log "WSL is operational. Status: $($wslStatusOutput.Trim())" -Level INFO
} catch { Write-Log "CRITICAL ERROR: WSL not operational. $($_.Exception.Message)" -L ERROR; $null=Show-MessageBoxWrapper -T "WSL not installed/configured or 'wsl --status' failed.`nEnsure WSL is functional.`nError: $($_.Exception.Message)" -C "Critical WSL Error" -I Stop; exit 1 }

$Global:AvailableWslDistros = @() 
function Update-AvailableWslDistros {
    Write-Log "Updating list of WSL distributions..." -Level INFO; $distrosTemp = @()
    try {
        $psiList=New-Object System.Diagnostics.ProcessStartInfo; $psiList.FileName="wsl.exe"; $psiList.Arguments="--list --quiet"; $psiList.UseShellExecute=$false; $psiList.RedirectStandardOutput=$true; $psiList.RedirectStandardError=$true; $psiList.CreateNoWindow=$true; $psiList.StandardOutputEncoding=[System.Text.Encoding]::UTF8
        $processList=New-Object System.Diagnostics.Process; $processList.StartInfo=$psiList; $processList.Start()|Out-Null
        $rawOutputList=$processList.StandardOutput.ReadToEnd(); $rawErrorList=$processList.StandardError.ReadToEnd(); $processList.WaitForExit()
        if($processList.ExitCode -ne 0){throw "wsl --list --quiet failed with exit code $($processList.ExitCode). Error: $($rawErrorList.Trim())"}
        $distrosTemp=$rawOutputList -split "[\r\n]+" | Where-Object {$_ -ne $null -and $_.Trim() -ne ""} | ForEach-Object {$_.Trim()}
        $Global:AvailableWslDistros = $distrosTemp; Write-Log "Available distributions after processing: $($Global:AvailableWslDistros -join ', ')" -Level DEBUG
    } catch { Write-Log "Error fetching distributions: $($_.Exception.Message)" -L ERROR; $null=Show-MessageBoxWrapper -T "Error fetching WSL distributions.`n$($_.Exception.Message)" -C "WSL Detection Error" -I Error }
}
Update-AvailableWslDistros 

# --- Workflows ---
function Start-CloneWorkflow {
    Write-Log "Starting Clone Workflow..." -Level INFO
    if (-not $Global:AvailableWslDistros -or $Global:AvailableWslDistros.Count -eq 0) {
        $null = Show-MessageBoxWrapper -Text "No distributions available to clone." -Caption "Clone Impossible" -Icon Warning
        Update-AvailableWslDistros; if (-not $Global:AvailableWslDistros -or $Global:AvailableWslDistros.Count -eq 0) { return }
    }
    $defaultExportBaseDir = Join-Path -Path $env:TEMP -ChildPath "WMT_Exports_Temp" 
    if (-not (Test-Path $defaultExportBaseDir)) { New-Item -ItemType Directory -Path $defaultExportBaseDir -Force | Out-Null }

    $exportFormResult = Show-SelectDistroForExportForm -availableDistros $Global:AvailableWslDistros -DefaultExportDir $defaultExportBaseDir -FormTitle "Clone: Step 1 - Select Source & Temporary Export"
    # For cloning, compression is not offered in this step as the .tar is temporary.
    if (-not $exportFormResult -or $exportFormResult.DialogResult -ne 'OK' -or (-not $exportFormResult.SelectedDistro)) { Write-Log "Clone (Step 1) cancelled or invalid." -L INFO; return } 

    $SourceDistro = $exportFormResult.SelectedDistro
    $TempTarPath = $exportFormResult.ExportPath 
    Write-Log "Cloning: Source='$SourceDistro', Temporary export to='$TempTarPath'." -L INFO

    $details = Get-WslDistroDetails -DistroName $SourceDistro
    if ($details.State -eq 'Running') {
        $stopChoice = Show-MessageBoxWrapper -T "'$SourceDistro' is running.`nStop it to clone?" -C "Stop Required" -B YesNo -I Question
        if ($stopChoice -eq 'Yes') { Write-Log "Stopping '$SourceDistro'..." -L INFO; wsl.exe --terminate "$SourceDistro" 2>&1|Out-Null; if($LASTEXITCODE -ne 0){Write-Log "Failed to stop '$SourceDistro'." -L ERROR; $null=Show-MessageBoxWrapper -T "Could not stop '$SourceDistro'." -C "Error" -I Error; return}; Write-Log "'$SourceDistro' stopped." -L SUCCESS; Start-Sleep -Sec 2 }
        else { Write-Log "Clone cancelled, distribution not stopped." -L INFO; return }
    }
    if (-not (Export-WslDistribution -DistroNameToExport $SourceDistro -PathToExportTo $TempTarPath)) { Write-Log "Export failed for cloning." -L ERROR; return }

    Update-AvailableWslDistros 
    $cloneDetailsFormResult = Show-GetCloneDetailsForm -OriginalDistroName $SourceDistro -existingDistrosList $Global:AvailableWslDistros
    if (-not $cloneDetailsFormResult -or $cloneDetailsFormResult.DialogResult -ne 'OK' -or (-not $cloneDetailsFormResult.NewCloneName)) { 
        Write-Log "Clone (Step 2) cancelled or invalid." -L INFO
        Write-Log "Temporarily exported file is at '$TempTarPath'. You can delete it manually or import it later." -Level WARN
        $null=Show-MessageBoxWrapper -Text "Cloning cancelled. Exported file '$TempTarPath' kept temporarily." -Caption "Clone Cancelled" -Icon Information
        return
    }
    $NewCloneName = $cloneDetailsFormResult.NewCloneName
    $TargetInstallDir = $cloneDetailsFormResult.InstallPath
    Write-Log "Cloning: New Name='$NewCloneName', Install Directory='$TargetInstallDir'." -L INFO

    if (Import-WslDistribution -NewDistroName $NewCloneName -InstallPath $TargetInstallDir -TarFilePathToImport $TempTarPath) {
        $null = Show-MessageBoxWrapper -Text "Successfully cloned '$SourceDistro' to '$NewCloneName'!" -Caption "Clone Successful" -Icon Information
        Update-AvailableWslDistros
        if (Test-Path $TempTarPath) { Write-Log "Deleting temporary .tar file '$TempTarPath'..." -L INFO; Remove-Item -Path $TempTarPath -Force -EA SilentlyContinue }
        $delOrigChoice = Show-MessageBoxWrapper -T "Do you want to delete the original distribution '$SourceDistro'?" -C "Cleanup" -B YesNo -I Question
        if ($delOrigChoice -eq 'Yes') { Write-Log "Deleting original '$SourceDistro'..." -L INFO; wsl.exe --unregister "$SourceDistro" 2>&1|Out-Null; if($LASTEXITCODE -ne 0){Write-Log "Failed to delete '$SourceDistro'." -L ERROR}else{Write-Log "'$SourceDistro' deleted." -L SUCCESS} }
    } 
}

function Start-ExportWorkflow {
    param ([array]$Distros)
    Write-Log "Starting Export Workflow..." -Level INFO
    if (-not $Distros -or $Distros.Count -eq 0) {
        $null = Show-MessageBoxWrapper -Text "No WSL distributions available for export." -Caption "Export Impossible" -Icon Warning
        Update-AvailableWslDistros; if (-not $Global:AvailableWslDistros -or $Global:AvailableWslDistros.Count -eq 0) { return }; $Distros = $Global:AvailableWslDistros
    }
    $defaultExportBaseDir = Join-Path -Path $env:USERPROFILE -ChildPath "Downloads"
    $exportFormResult = Show-SelectDistroForExportForm -availableDistros $Distros -DefaultExportDir $defaultExportBaseDir
    if (-not $exportFormResult -or $exportFormResult.DialogResult -ne 'OK' -or (-not $exportFormResult.SelectedDistro)) { Write-Log "Export cancelled or invalid." -L INFO; return }
    
    $SourceDistro = $exportFormResult.SelectedDistro; 
    $ExportedTarPath = $exportFormResult.ExportPath 
    $ShouldCompressOutput = $exportFormResult.Compress 
    $FinalExportPath = $ExportedTarPath 

    Write-Log "Export requested for '$SourceDistro' to '$ExportedTarPath'. Compress: $ShouldCompressOutput" -L INFO
    $details = Get-WslDistroDetails -DistroName $SourceDistro
    if ($details.State -eq 'Running') {
        $stopChoice = Show-MessageBoxWrapper -T "'$SourceDistro' is running.`nStop it to export?" -C "Stop Required" -B YesNo -I Question
        if ($stopChoice -eq 'Yes') { Write-Log "Stopping '$SourceDistro'..." -L INFO; wsl.exe --terminate "$SourceDistro" 2>&1|Out-Null; if($LASTEXITCODE -ne 0){Write-Log "Failed to stop '$SourceDistro'." -L ERROR; $null=Show-MessageBoxWrapper -T "Could not stop '$SourceDistro'." -C "Error" -I Error; return}; Write-Log "'$SourceDistro' stopped." -L SUCCESS; Start-Sleep -Sec 2 }
        else { Write-Log "Export cancelled, distribution not stopped." -L INFO; return }
    }
    if (Export-WslDistribution -DistroNameToExport $SourceDistro -PathToExportTo $ExportedTarPath) {
        $null = Show-MessageBoxWrapper -Text "Export of '$SourceDistro' to '$ExportedTarPath' completed successfully!" -Caption "Export Successful" -Icon Information
        
        if ($ShouldCompressOutput) {
            $zipPath = $ExportedTarPath -replace '\.tar$', '.zip'
            Write-Log "Attempting compression to '$zipPath'..." -L INFO
            $swCompress = [System.Diagnostics.Stopwatch]::StartNew()
            Write-Host "Compressing... (this may take a while)" # Message simple pendant la compression synchrone
            
            if (Invoke-AdvancedCompression -SourceFilePath $ExportedTarPath -DestinationZipPath $zipPath) {
                $swCompress.Stop()
                Write-Log "Compression to '$zipPath' successful in $($swCompress.Elapsed.ToString('hh\:mm\:ss'))." -L SUCCESS
                $null = Show-MessageBoxWrapper -Text "Compression to '$zipPath' successful in $($swCompress.Elapsed.ToString('hh\:mm\:ss'))." -Caption "Compression Successful" -Icon Information
                Write-Log "Deleting original .tar file '$ExportedTarPath'." -L INFO; Remove-Item $ExportedTarPath -Fo -EA SilentlyContinue
                $FinalExportPath = $zipPath
            } else {
                $swCompress.Stop()
                Write-Log "Compression failed after $($swCompress.Elapsed.ToString('hh\:mm\:ss')). Original .tar file '$ExportedTarPath' kept." -L ERROR
                $null = Show-MessageBoxWrapper -Text "Compression failed. Original .tar file '$ExportedTarPath' has been kept." -Caption "Compression Error" -Icon Error
            }
        } else { Write-Log "Compression skipped." -L INFO }
        Write-Log "Final export file: $FinalExportPath" -Level INFO
    }
}

function Start-ImportWorkflow {
    param ([array]$CurrentDistros) 
    Write-Log "Starting Import Workflow..." -Level INFO
    $importDetails = Show-GetImportDetailsForm -existingDistrosList $CurrentDistros
    if (-not $importDetails -or $importDetails.DialogResult -ne 'OK' -or (-not $importDetails.SourceArchivePath)) { Write-Log "Import cancelled or invalid." -L INFO; return }

    $SourceArchivePath = $importDetails.SourceArchivePath 
    $NewName = $importDetails.NewDistroName
    $TargetInstallDir = $importDetails.InstallPath
    $TarFileToImport = ""; $IsTempTar = $false
    $TempTarExtractionDir = Join-Path -Path $env:TEMP -ChildPath "WMT_Import_Temp_$(Get-Random)" 

    try {
        if ($SourceArchivePath.ToLower().EndsWith(".zip")) {
            Write-Log "Source file is a .zip. Attempting decompression..." -Level INFO
            if (-not (Test-Path $TempTarExtractionDir)) { New-Item -ItemType Directory -Path $TempTarExtractionDir -Force | Out-Null }
            
            $swDecompress = [System.Diagnostics.Stopwatch]::StartNew()
            Write-Host "Decompressing '$SourceArchivePath'... (this may take a while)"

            if (Invoke-AdvancedDecompression -SourceZipPath $SourceArchivePath -DestinationExtractPath $TempTarExtractionDir) {
                $swDecompress.Stop()
                Write-Log "Decompression successful in $($swDecompress.Elapsed.ToString('hh\:mm\:ss'))." -L SUCCESS
                $tarFilesFound = Get-ChildItem -Path $TempTarExtractionDir -Filter "*.tar"
                if ($tarFilesFound.Count -eq 1) { $TarFileToImport = $tarFilesFound[0].FullName; $IsTempTar = $true; Write-Log "Decompression OK. Temporary .tar: $TarFileToImport" -L SUCCESS }
                elseif ($tarFilesFound.Count -gt 1) { throw "Multiple .tar files found in decompression folder '$TempTarExtractionDir'." }
                else { throw "No .tar file found after decompressing '$SourceArchivePath' into '$TempTarExtractionDir'." }
            } else { $swDecompress.Stop(); throw "Failed to decompress '$SourceArchivePath'." }
        } elseif ($SourceArchivePath.ToLower().EndsWith(".tar")) { $TarFileToImport = $SourceArchivePath }
        else { throw "Unsupported source file type: '$SourceArchivePath'. Only .tar and .zip are accepted." }

        Write-Log "Importing: TAR File='$TarFileToImport', Name='$NewName', Directory='$TargetInstallDir'." -L INFO
        if (Import-WslDistribution -NewDistroName $NewName -InstallPath $TargetInstallDir -TarFilePathToImport $TarFileToImport) {
            $null = Show-MessageBoxWrapper -Text "Import of '$NewName' successful!" -Caption "Import Successful" -Icon Information
            Update-AvailableWslDistros 
        }
    } catch {
        Write-Log "Error in import workflow: $($_.Exception.Message)" -Level ERROR
        $null = Show-MessageBoxWrapper -Text "Error during import process: $($_.Exception.Message)" -Caption "Import Error" -Icon Error
    } finally {
        if ($IsTempTar -and (Test-Path $TarFileToImport)) { Write-Log "Deleting temporary decompressed .tar: $TarFileToImport" -L INFO; Remove-Item $TarFileToImport -Fo -EA SilentlyContinue }
        if (Test-Path $TempTarExtractionDir -PathType Container) { Write-Log "Deleting temporary extraction folder: $TempTarExtractionDir" -L INFO; Remove-Item $TempTarExtractionDir -Recurse -Fo -EA SilentlyContinue }
    }
}

# --- Main Menu Loop ---
$userChoice = ''
do {
    Update-AvailableWslDistros 
    $userChoice = Show-MainMenuForm
    switch ($userChoice) {
        'Clone'  { Start-CloneWorkflow  } 
        'Export' { Start-ExportWorkflow -Distros $Global:AvailableWslDistros }
        'Import' { Start-ImportWorkflow -CurrentDistros $Global:AvailableWslDistros }
        'Quit'   { Write-Log "User chose to quit." -Level INFO }
        default  { Write-Log "Menu closed or invalid choice ($userChoice)." -Level WARN } 
    }
} while ($userChoice -ne 'Quit')

Write-Log "--- Exiting WSL Management Tool (WMT) ---" -Level INFO
#endregion

