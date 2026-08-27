# Requires PowerShell 7+
# Install once if needed:
# Install-Module Microsoft.Graph.Users -Scope CurrentUser
# Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

param(
	[Parameter(Mandatory = $true)]
	[string]$InputCsv,

	[string]$Out
)

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users

function Get-InputEmailColumnName {
	param(
		[Parameter(Mandatory = $true)]
		[object[]]$CsvRows
	)

	if (-not $CsvRows -or $CsvRows.Count -eq 0) {
		throw "Input CSV does not contain any rows: $InputCsv"
	}

	$availableColumns = @($CsvRows[0].PSObject.Properties.Name)
	$emailColumnCandidates = @('Email', 'email', 'Mail', 'mail', 'UserPrincipalName', 'userPrincipalName', 'UPN', 'upn')
	$emailColumn = $emailColumnCandidates | Where-Object { $availableColumns -contains $_ } | Select-Object -First 1

	if (-not $emailColumn) {
		throw "Input CSV must contain one of these columns: $($emailColumnCandidates -join ', '). Available columns: $($availableColumns -join ', ')"
	}

	return $emailColumn
}

function Import-InputCsv {
	param(
		[Parameter(Mandatory = $true)]
		[string]$CsvPath
	)

	if (-not (Test-Path -LiteralPath $CsvPath)) {
		throw "Input CSV not found: $CsvPath"
	}

	$allLines = Get-Content -LiteralPath $CsvPath
	if (-not $allLines -or $allLines.Count -eq 0) {
		return @()
	}

	$firstLine = $allLines[0]
	$delimiter = ','
	$startIndex = 0

	if ($firstLine -match '^sep=(.)$') {
		$delimiter = $Matches[1]
		$startIndex = 1
		if ($allLines.Count -le 1) {
			return @()
		}
		$firstLine = $allLines[1]
	}

	if ($startIndex -eq 0 -and $firstLine -match ';') {
		$delimiter = ';'
	} elseif ($startIndex -eq 0 -and $firstLine -match "`t") {
		$delimiter = "`t"
	}

	if ($startIndex -eq 0) {
		return Import-Csv -LiteralPath $CsvPath -Delimiter $delimiter
	}

	return $allLines[$startIndex..($allLines.Count - 1)] | ConvertFrom-Csv -Delimiter $delimiter
}

function Find-UserByEmail {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Email
	)

	try {
		return Get-MgUser -UserId $Email -Property Id,DisplayName,Mail,UserPrincipalName,AccountEnabled -ErrorAction Stop
	}
	catch {
		$escapedEmail = $Email.Replace("'", "''")

		$matches = Get-MgUser `
			-Filter "mail eq '$escapedEmail' or userPrincipalName eq '$escapedEmail'" `
			-Property Id,DisplayName,Mail,UserPrincipalName,AccountEnabled `
			-ConsistencyLevel eventual `
			-ErrorAction SilentlyContinue

		return $matches | Select-Object -First 1
	}
}

Connect-MgGraph -Scopes "User.Read.All" | Out-Null

try {
	$rows = Import-InputCsv -CsvPath $InputCsv
	$emailColumn = Get-InputEmailColumnName -CsvRows $rows
	$results = New-Object System.Collections.Generic.List[object]

	foreach ($row in $rows) {
		$email = [string]$row.$emailColumn

		if ([string]::IsNullOrWhiteSpace($email)) {
			continue
		}

		$email = $email.Trim()
		Write-Host "Checking $email"

		$user = Find-UserByEmail -Email $email

		if ($user) {
			$status = if ($user.AccountEnabled -eq $false) { 'disabled' } else { 'active' }

			$results.Add([pscustomobject]@{
				Email  = $email
				Name   = $user.DisplayName
				Status = $status
			})

			continue
		}

		$results.Add([pscustomobject]@{
			Email  = $email
			Name   = ''
			Status = 'not found'
		})
	}

	if (-not [string]::IsNullOrWhiteSpace($Out)) {
		$resolvedFileName = [System.IO.Path]::GetFileName($Out)
		if ([string]::IsNullOrWhiteSpace($resolvedFileName)) {
			throw "Out must be a valid file name, for example invalid-users.csv"
		}

		if ([System.IO.Path]::GetExtension($resolvedFileName) -ne '.csv') {
			$resolvedFileName = "$resolvedFileName.csv"
		}

		$outputCsvPath = Join-Path -Path (Get-Location) -ChildPath $resolvedFileName
		$results | Export-Csv -LiteralPath $outputCsvPath -NoTypeInformation -Encoding UTF8
		Write-Host "CSV file created: $outputCsvPath"
	}

	if ($IsWindows) {
		$results | Out-GridView -Title "Users by Email Status"
	} else {
		$results | Format-Table -AutoSize
	}
}
finally {
	Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
