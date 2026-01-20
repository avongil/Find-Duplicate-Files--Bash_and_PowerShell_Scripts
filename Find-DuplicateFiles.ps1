<#
.SYNOPSIS
    Identifies duplicate files on a network drive or folder by size and content hash,
    or alternatively by filename + size only (fast pre-check).

.DESCRIPTION
    Recursively scans the specified path(s).
    - Default / hash mode: groups files by size → computes selected hash → finds true duplicates
    - NameAndSize mode: groups files by filename (case-insensitive) + size → reports likely duplicates
    Results are displayed in console and can be exported to CSV.

.PARAMETER Path
    The root path(s) to scan (accepts array).

.PARAMETER Exclude
    Optional array of folder paths/patterns to exclude (not yet implemented in this version).

.PARAMETER CompareMode
    Determines how duplicates are detected:
    - SHA256  (default) → most accurate, slowest
    - SHA1    → balanced
    - MD5     → fastest hash but less collision-resistant
    - NandS   → filename (case-insensitive) + size only → very fast, first-pass check

.PARAMETER ExportPath
    Optional: Full path to export results as CSV.

.PARAMETER MaxFilesToDisplay
    Maximum number of files to display per duplicate group before summarizing (default: 10).

.PARAMETER ShowProgress
    Display detailed progress information during scanning and processing.

.EXAMPLE
    .\Find-DuplicateFiles.ps1 -Path 'X:\', 'W:\' -CompareMode NandS -ExportPath 'C:\dupes.csv'

.EXAMPLE
    .\Find-DuplicateFiles.ps1 -Path 'X:\' -CompareMode SHA256 -MaxFilesToDisplay 5 -ShowProgress
	
.EXAMPLE 
    .\Find-DuplicateFiles.ps1 -Path 'X:\', 'W:\' -Exclude 'X:\Cobian_Incremental_NextcloudGMT_Backup' -CompareMode NandS -MaxFilesToDisplay 3 -ShowProgress -ExportPath '\Scripts\FindDuplicates\dupes-kirk.csv'
#>

param (
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string[]]$Exclude = @(),

    [ValidateSet('SHA256', 'SHA1', 'MD5', 'NandS')]
    [string]$CompareMode = 'SHA256',

    [string]$ExportPath = $null,

    [int]$MaxFilesToDisplay = 10,

    [switch]$ShowProgress
)

# Validate paths
foreach ($p in $Path) {
    if (-not (Test-Path -Path $p)) {
        Write-Error "The specified path does not exist or is inaccessible: $p"
        exit 1
    }
}

Write-Host "Scanning for duplicates in: $($Path -join ', ')" -ForegroundColor Cyan
Write-Host "Comparison mode: $CompareMode" -ForegroundColor Cyan

if ($CompareMode -eq 'NandS') {
    Write-Host "Fast mode: matching by filename (case-insensitive) + size only" -ForegroundColor Yellow
} else {
    Write-Host "Using hash algorithm: $CompareMode" -ForegroundColor Cyan
    Write-Host "This may take considerable time on large network shares..." -ForegroundColor Yellow
}

# ────────────────────────────────────────────────────────────────
# Collect all files
# ────────────────────────────────────────────────────────────────
if ($ShowProgress) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Starting file enumeration..." -ForegroundColor Cyan
}

$allFiles = @()
$fileCounter = 0
foreach ($p in $Path) {
    if ($ShowProgress) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Scanning path: $p" -ForegroundColor Cyan
    }
    
    $pathFiles = Get-ChildItem -Path $p -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $fileCounter++
        if ($ShowProgress) {
            Write-Progress -Activity "Scanning files" -Status "Found $fileCounter files..." -Id 1
        }
        $_
    }
    $allFiles += $pathFiles
}

if ($ShowProgress) {
    Write-Progress -Activity "Scanning files" -Completed -Id 1
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] File enumeration complete. Total files: $($allFiles.Count)" -ForegroundColor Cyan
}

if ($allFiles.Count -eq 0) {
    Write-Host "No files found in the specified path(s)." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($allFiles.Count) files. Analyzing..." -ForegroundColor Cyan

if ($ShowProgress) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting duplicate analysis..." -ForegroundColor Cyan
}

# ────────────────────────────────────────────────────────────────
# NandS mode – filename + size only
# ────────────────────────────────────────────────────────────────
if ($CompareMode -eq 'NandS') {

    if ($ShowProgress) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Grouping files by name and size..." -ForegroundColor Cyan
        Write-Progress -Activity "Analyzing duplicates" -Status "Grouping by name and size..." -Id 2
    }

    $duplicates = $allFiles |
        Group-Object { "$($_.Name.ToLower())|$($_.Length)" } |
        Where-Object { $_.Count -gt 1 }

    if ($ShowProgress) {
        Write-Progress -Activity "Analyzing duplicates" -Completed -Id 2
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Grouping complete. Found $($duplicates.Count) duplicate groups." -ForegroundColor Cyan
    }

    if ($duplicates.Count -eq 0) {
        Write-Host "No files with identical name (case-insensitive) and size found." -ForegroundColor Green
        exit 0
    }

    $report = @()

    $groupCount = $duplicates.Count
    Write-Host "`nPotential duplicate groups (Name + Size match) - $groupCount groups:" -ForegroundColor Magenta

    foreach ($group in $duplicates) {
        $nameSizeParts = $group.Name -split '\|', 2
        $name = $nameSizeParts[0]
        $size = [long]$nameSizeParts[1]

        # Use separate variable for clarity and to avoid nesting issues
        $sizeFormatted = '{0:N0}' -f $size
        $fileCount = $group.Count

        Write-Host "`nName: $name   Size: $sizeFormatted bytes   - $fileCount files" -ForegroundColor Yellow
        
        $files = $group.Group | Sort-Object FullName
        
        if ($fileCount -gt $MaxFilesToDisplay) {
            # Display first MaxFilesToDisplay files
            $displayFiles = $files | Select-Object -First $MaxFilesToDisplay
            foreach ($file in $displayFiles) {
                $filePath = $file.FullName
                Write-Host "  $filePath" -ForegroundColor White
                $report += [PSCustomObject]@{
                    Name       = $file.Name
                    SizeBytes  = $file.Length
                    Path       = $file.FullName
                    Mode       = 'NameAndSize'
                }
            }
            
            # Get first and last file names for summary
            $firstName = ($files | Select-Object -First 1).Name
            $lastName = ($files | Select-Object -Last 1).Name
            $remainingCount = $fileCount - $MaxFilesToDisplay
            
            Write-Host "  ... and $remainingCount more files" -ForegroundColor Gray
            Write-Host "  (Total: $fileCount duplicate files from '$firstName' to '$lastName')" -ForegroundColor Gray
            
            # Still add remaining files to report for export
            $remainingFiles = $files | Select-Object -Skip $MaxFilesToDisplay
            foreach ($file in $remainingFiles) {
                $report += [PSCustomObject]@{
                    Name       = $file.Name
                    SizeBytes  = $file.Length
                    Path       = $file.FullName
                    Mode       = 'NameAndSize'
                }
            }
        }
        else {
            # Display all files
            foreach ($file in $files) {
                $filePath = $file.FullName
                Write-Host "  $filePath" -ForegroundColor White
                $report += [PSCustomObject]@{
                    Name       = $file.Name
                    SizeBytes  = $file.Length
                    Path       = $file.FullName
                    Mode       = 'NameAndSize'
                }
            }
        }
    }
}

# ────────────────────────────────────────────────────────────────
# Hash-based modes (SHA256 / SHA1 / MD5)
# ────────────────────────────────────────────────────────────────
else {

    if ($ShowProgress) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Grouping files by size..." -ForegroundColor Cyan
        Write-Progress -Activity "Analyzing duplicates" -Status "Grouping by size..." -Id 2
    }

    # Stage 1: Group by size (fast pre-filter)
    $filesBySize = $allFiles |
        Group-Object -Property Length |
        Where-Object { $_.Count -gt 1 }

    if ($ShowProgress) {
        Write-Progress -Activity "Analyzing duplicates" -Completed -Id 2
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($filesBySize.Count) size groups with potential duplicates." -ForegroundColor Cyan
    }

    if ($filesBySize.Count -eq 0) {
        Write-Host "No files with matching sizes found. No duplicates possible." -ForegroundColor Green
        exit 0
    }

    Write-Host "Found $($filesBySize.Count) candidate groups by size. Computing hashes..." -ForegroundColor Cyan

    # Flatten candidates and compute hashes
    $hashCandidates = $filesBySize | ForEach-Object { $_.Group }
    $totalToHash = $hashCandidates.Count

    if ($ShowProgress) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Computing $CompareMode hashes for $totalToHash candidate files..." -ForegroundColor Cyan
    }

    $hashCounter = 0
    $duplicates = $hashCandidates |
        ForEach-Object {
            $hashCounter++
            if ($ShowProgress) {
                $percentComplete = [math]::Round(($hashCounter / $totalToHash) * 100)
                Write-Progress -Activity "Computing file hashes" -Status "Processing file $hashCounter of $totalToHash" -PercentComplete $percentComplete -Id 3
            }
            Get-FileHash -Path $_.FullName -Algorithm $CompareMode -ErrorAction SilentlyContinue
        } |
        Group-Object -Property Hash |
        Where-Object { $_.Count -gt 1 }

    if ($ShowProgress) {
        Write-Progress -Activity "Computing file hashes" -Completed -Id 3
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Hash computation complete. Found $($duplicates.Count) duplicate groups." -ForegroundColor Cyan
    }

    if ($duplicates.Count -eq 0) {
        Write-Host "No duplicate files found (no matching content hashes)." -ForegroundColor Green
        exit 0
    }

    $report = @()

    $groupCount = $duplicates.Count
    Write-Host "`nDuplicate file groups found - $groupCount groups:" -ForegroundColor Magenta

    foreach ($group in $duplicates) {
        $fileCount = $group.Count
        $hashValue = $group.Name
        Write-Host "`nHash: $hashValue  - $fileCount files" -ForegroundColor Yellow
        
        $files = $group.Group | Sort-Object Path
        
        if ($fileCount -gt $MaxFilesToDisplay) {
            # Display first MaxFilesToDisplay files
            $displayFiles = $files | Select-Object -First $MaxFilesToDisplay
            foreach ($file in $displayFiles) {
                $filePath = $file.Path
                Write-Host "  $filePath" -ForegroundColor White
                $report += [PSCustomObject]@{
                    Hash       = $group.Name
                    FilePath   = $file.Path
                    SizeBytes  = $file.Length
                    Algorithm  = $CompareMode
                }
            }
            
            # Get first and last file names for summary
            $firstFile = $files | Select-Object -First 1
            $lastFile = $files | Select-Object -Last 1
            $firstName = Split-Path -Leaf $firstFile.Path
            $lastName = Split-Path -Leaf $lastFile.Path
            $remainingCount = $fileCount - $MaxFilesToDisplay
            
            Write-Host "  ... and $remainingCount more files" -ForegroundColor Gray
            Write-Host "  (Total: $fileCount duplicate files from '$firstName' to '$lastName')" -ForegroundColor Gray
            
            # Still add remaining files to report for export
            $remainingFiles = $files | Select-Object -Skip $MaxFilesToDisplay
            foreach ($file in $remainingFiles) {
                $report += [PSCustomObject]@{
                    Hash       = $group.Name
                    FilePath   = $file.Path
                    SizeBytes  = $file.Length
                    Algorithm  = $CompareMode
                }
            }
        }
        else {
            # Display all files
            foreach ($file in $files) {
                $filePath = $file.Path
                Write-Host "  $filePath" -ForegroundColor White
                $report += [PSCustomObject]@{
                    Hash       = $group.Name
                    FilePath   = $file.Path
                    SizeBytes  = $file.Length
                    Algorithm  = $CompareMode
                }
            }
        }
    }
}

# ────────────────────────────────────────────────────────────────
# Export if requested
# ────────────────────────────────────────────────────────────────
if ($ExportPath -and $report) {
    $report | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults exported to: $ExportPath" -ForegroundColor Green
}

Write-Host "`nScan complete." -ForegroundColor Cyan
