param (
	[string]$runtime = "",
	[long]$repeat = 5,
	[switch]$quiet,
	[string]$filter = "."
)

# -runtime checks
$bin = ""
if ($runtime -eq "iojs") {
	$bin = "electron"
} elseif ($runtime -eq "node") {
	$bin = "node"
} else {
	Write-Host ("Runtime '{0}' is not supported." -f $runtime)
	exit 0
}
Write-Host ("Using Runtime '{0}' as '{1}'..." -f $runtime, $bin)

$Root = (Resolve-Path .\).Path
[string[]]$blacklist = "helpers", "tools"

class Test
{
	[ValidateNotNullOrEmpty()][string]$Category
	[ValidateNotNullOrEmpty()][string]$Name
	[ValidateNotNullOrEmpty()][string]$File
	# Test Info
	[string]$Framework
	[string]$Outcome
	[long]$Duration
	[string]$ErrorMessage
	[string]$ErrorStackTrace
	[string]$StdOut
	[string]$StdErr
	# System Info
	[string]$Runtime
	[bool]$Quiet
	
	Test([string]$c, [string]$n, [string]$f, [string]$rt, [bool]$q) {
		$this.Category = $c
		$this.Name = $n
		$this.File = $f
		$this.Framework = "Powershell"
		$this.Outcome = "None"
		$this.StdOut = ""
		$this.StdErr = ""
		$this.ErrorMessage = ""
		$this.ErrorStackTrace = ""
		$this.Runtime = $rt
		$this.Quiet = $q
	}
	
	# AppVeyor Invoker
	Register() {
		if ($Env:APPVEYOR) {
			$body = @{
				testName = $this.GetDisplayName()
				testFramework = $this.Framework
				fileName = $this.File
				durationMilliseconds = $this.Duration
				outcome = $this.Outcome
				ErrorMessage = $this.ErrorMessage
				ErrorStackTrace = $this.ErrorStackTrace
				StdOut = $this.StdOut
				StdErr = $this.StdErr
			}
			$body_json = $body | ConvertTo-Json -Compress
			Invoke-RestMethod -Method Post -Uri ("{0}api/tests" -f $Env:APPVEYOR_API_URL) -ContentType "application/json" -Body $body_json
		}
	}
	
	Update() {
		if ($Env:APPVEYOR) {
			$body = @{
				testName = $this.GetDisplayName()
				testFramework = $this.Framework
				fileName = $this.File
				durationMilliseconds = $this.Duration
				outcome = $this.Outcome
				ErrorMessage = $this.ErrorMessage
				ErrorStackTrace = $this.ErrorStackTrace
				StdOut = $this.StdOut
				StdErr = $this.StdErr
			}
			$body_json = $body | ConvertTo-Json -Compress
			Invoke-RestMethod -Method Put -Uri ("{0}api/tests" -f $Env:APPVEYOR_API_URL) -ContentType "application/json" -Body $body_json
		}
	}
	
	# Setters, Getters
	[string]GetDisplayName() {
		return ("{0}/{1}" -f $this.Category, $this.Name)
	}
	
	SetOutcome([string]$o) {
		$this.Outcome = $o
		$this.Update()
	}
	
	AppendStdOut([string]$o) {
		$this.StdOut = ("{0}{1}" -f $this.StdOut, $o)
		$this.Update()
	}
	
	AppendStdErr([string]$o) {
		$this.StdErr = ("{0}{1}" -f $this.StdErr, $o)
		$this.Update()
	}
	
	AddRunTime([long]$t) {
		$this.Duration += $t
		$this.Update()
	}
	
	SetErrorMessage([string]$msg) {
		$this.ErrorMessage = $msg
		$this.Update()
	}
	
	# Runners
	[bool]Execute([int]$it) {
		$root = (Resolve-Path .\).Path
		$stat_output = ""
		$safe_output = ""
		$stat_error = ""
		$safe_error = ""
		$rcode = $true
		$timeout = $false
		$timeouted = $null		
		$fit = $it + 1
		
		Write-Host -NoNewline ("    Try {0}... " -f $fit)
		
		$this.AppendStdOut(("> Output log for #{0}:`n" -f $fit))
		$this.AppendStdErr(("> Error log for #{0}:`n" -f $fit))
		
		$bin = $this.Runtime
		
		Remove-Item stdout.log -ea 0
		Remove-Item stderr.log -ea 0
		
		$sw = [Diagnostics.Stopwatch]::StartNew()
		$proc = Start-Process -FilePath "$bin" -WorkingDirectory ("{0}\tests\{1}\" -f $root, $this.Category) -ArgumentList ("`"{0}`"" -f $this.File) -RedirectStandardOutput stdout.log -RedirectStandardError stderr.log -PassThru -NoNewWindow
		$proc | Wait-Process -Timeout 30 -ea 0 -ev timeouted
		$sw.Stop()
		
		if ($proc.hasExited -ne $true) {
			$proc.Kill()
		}
		if ($timeouted)  {
			$timeout = $true
		}
				
		$this.AddRunTime($sw.Elapsed.TotalMilliseconds)
		
		# Sanitize stdout/stderr.
		$stat_output = Get-Content -Path stdout.log -Force -Raw -ReadCount 0
		$stat_error = Get-Content -Path stderr.log -Force -Raw -ReadCount 0
		if ($stat_output) {
			$safe_output = ("{0}" -f $stat_output)
		}
		if ($stat_error) {
			$safe_error = ("{0}" -f $stat_error)
		}
		$this.AppendStdOut($safe_output)
		$this.AppendStdErr($safe_error)
		
		$this.AppendStdOut(("> Output log for #{0} complete.`n`n" -f $fit))
		$this.AppendStdErr(("> Error log for #{0} complete.`n`n" -f $fit))

		if ($timeout -eq $true) {
			Write-Host "Timed Out"
			$ecode = $false
		} elseif ($proc.ExitCode -eq 0) {
			Write-Host "Success"
			$ecode = $true
		} else {
			Write-Host "Failed"
			$ecode = $false
		}

		if (!$Env:APPVEYOR -And !$this.Quiet) {
			Write-Host "StdOut: $safe_output"
			Write-Host "StdErr: $safe_error"
		}
		
		return $ecode
	}
	
	[bool]Run([int]$its) {
		$rcode = $true
		$failed_count = 0
		
		Write-Host ("Test '{0}' running..." -f $this.GetDisplayName())
		$this.SetOutcome("Running");
		For ($i = 0; $i -lt $its; $i++) {
			$result = $this.Execute($i)
			if ($result -eq $false) {
				$rcode = $false
				$failed_count++
			}
		}
		if ($failed_count -eq 0) {
			$this.SetOutcome("Passed")
			$this.SetErrorMessage(("{0} out of {1} tests failed." -f $failed_count, $its))
		} elseif ($failed_count -eq $its) {
			$this.SetOutcome("Failed")
			$this.SetErrorMessage(("{0} out of {1} tests failed." -f $failed_count, $its))
		} else {
			$this.SetOutcome("Inconclusive")
			$this.SetErrorMessage(("{0} out of {1} tests failed." -f $failed_count, $its))
		}
		
		return $rcode
	}
}
[Test[]]$Tests = @()

# Detect Test Categories
$Categories = Get-ChildItem -Path $Root/tests/ -Name -Directory
ForEach($Category in $Categories) {
	$skip = $false
	ForEach($CatBl in $blacklist) {
		If ($CatBl -eq $Category) {
			$skip = $true
		}
	}
	If ($skip -eq $true) {
		continue
	}

	Write-Host "Category '$Category'..."
	# Detect Tests
	$Files = Get-ChildItem -Path $Root\tests\$Category\ -Filter *.js -Name -File
	ForEach($File in $Files) {
		# Convert File Name to proper name by stripping .js from it.
		$Name = $File.Substring(0, $File.length - 3)
		
		# Match against $filter
		$Match = ("{0}/{1}" -f $Category, $Name) -match ("{0}" -f $filter)
		
		if ($Match) {
			# Store Test for later use.
			$Test = [Test]::new($Category, $Name, "$Root\tests\$Category\$File", $bin, $quiet)
			$Tests += $Test
		
			# Register
			$Test.Register()			
			Write-Host "    Test '$Name' registered."
		} else {
			Write-Host ("    Test '{0}' not registered, doesn't match filter '{1}'." -f $Name, $filter)
		}
	}
}

# Run Tests
$ErrorCode = 0
ForEach($Test in $Tests) {
	$result = $Test.Run($repeat)
	if ($result -eq $false) {
		$ErrorCode = 1
	}
}

exit $ErrorCode