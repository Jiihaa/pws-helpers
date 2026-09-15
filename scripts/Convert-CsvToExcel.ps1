[CmdletBinding()]
param(
    [Parameter()]
    [string]$Folder = $PSScriptRoot
)

if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
    throw "Folder '$Folder' does not exist or is not a directory."
}

$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false

$csvFiles = Get-ChildItem -Path $Folder -Filter *.csv -File

if (-not $csvFiles) {
    Write-Host "No CSV files found in $folder"
    $excel.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
    exit
}

foreach ($csvFile in $csvFiles) {
    $csvPath = $csvFile.FullName
    $xlsxPath = [System.IO.Path]::ChangeExtension($csvPath, ".xlsx")

    if (Test-Path -LiteralPath $xlsxPath) {
        Remove-Item -LiteralPath $xlsxPath -Force
    }

    Write-Host "Converting $($csvFile.Name)..."

    $data = Import-Csv -Path $csvPath

    $workbook = $excel.Workbooks.Add()
    $worksheet = $workbook.Worksheets.Item(1)

    $sheetName = [System.IO.Path]::GetFileNameWithoutExtension($csvFile.Name)
    $sheetName = $sheetName -replace '[\\/:\?\*\[\]]', ' '
    $sheetName = $sheetName.Trim()
    if ([string]::IsNullOrWhiteSpace($sheetName)) {
        $sheetName = 'Sheet1'
    }
    if ($sheetName.Length -gt 31) {
        $sheetName = $sheetName.Substring(0, 31)
    }
    $worksheet.Name = $sheetName

    if ($data -and $data.Count -gt 0) {
        $headers = @($data[0].PSObject.Properties.Name)

        for ($colIndex = 0; $colIndex -lt $headers.Count; $colIndex++) {
            $worksheet.Cells.Item(1, $colIndex + 1) = $headers[$colIndex]
        }

        $rowIndex = 2
        foreach ($row in $data) {
            for ($colIndex = 0; $colIndex -lt $headers.Count; $colIndex++) {
                $header = $headers[$colIndex]
                $value = $row.$header
                if ($null -ne $value) {
                    $worksheet.Cells.Item($rowIndex, $colIndex + 1) = [string]$value
                }
            }
            $rowIndex++
        }
    }

    $worksheet.Columns.AutoFit()
    $workbook.SaveAs($xlsxPath, 51)
    $workbook.Close($false)
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($worksheet) | Out-Null
}

$excel.Quit()
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null

Write-Host "Done. Converted $($csvFiles.Count) CSV files to XLSX."