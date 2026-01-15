param(
  [string]$InputPbf = "",
  [string]$OutputWkp = "",
  # Bengaluru bbox (minLat,minLon,maxLat,maxLon)
  [string]$Bbox = "12.85,77.45,13.10,77.75",
  [switch]$UseOverpass,
  [int]$OverpassTiles = 5
)


$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

if (-not $InputPbf -or $InputPbf.Trim().Length -eq 0) {
  $InputPbf = Join-Path $PSScriptRoot "osm_data/southern-zone-latest.osm.pbf"
} else {
  $InputPbf = Join-Path $repoRoot $InputPbf
}

if (-not $OutputWkp -or $OutputWkp.Trim().Length -eq 0) {
  $OutputWkp = Join-Path $repoRoot "assets/osm/bengaluru.wkp"
} else {
  $OutputWkp = Join-Path $repoRoot $OutputWkp
}

if (-not $UseOverpass) {
  if (-not (Test-Path $InputPbf)) { throw "Input PBF not found: $InputPbf" }
}

$pythonExe = 'python'
$pythonBaseArgs = @('-u')
try {
  $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
  if ($pyLauncher) {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & py -3 -m pip --version *> $null
    $pipOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $oldEap
    if ($pipOk) {
      $pythonExe = 'py'
      $pythonBaseArgs = @('-3', '-u')
    }
  }
} catch {}

function Run-Python {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$PythonArgs
  )
  $display = (@($pythonExe) + $pythonBaseArgs + $PythonArgs) -join ' '
  Write-Host "Running: $display"
  & $pythonExe @pythonBaseArgs @PythonArgs
}

$runnerDisplay = (@($pythonExe) + $pythonBaseArgs) -join ' '

# Best-effort sanity check that the chosen runner exists
$oldEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
Run-Python @('--version') | Out-Null
$verOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $oldEap

if (-not $verOk) {
  throw "No usable python found (tried: $runnerDisplay)"
}

Write-Host "Using python runner: $runnerDisplay"

# Ensure osmium exists in the *active* python (only needed for PBF pipeline)
if (-not $UseOverpass) {
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  Run-Python @('-c', 'import osmium') *> $null
  $importCode = $LASTEXITCODE
  $ErrorActionPreference = $oldEap

  if ($importCode -ne 0) {
    Write-Host "Python package 'osmium' missing. Installing..."
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Run-Python @('-m', 'pip', 'install', 'osmium')
    $pipCode = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    if ($pipCode -ne 0) {
      throw "Failed to install osmium into the active python environment"
    }

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Run-Python @('-c', 'import osmium') *> $null
    $importCode2 = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    if ($importCode2 -ne 0) {
      throw "osmium still not importable after install; check your python/pip environment"
    }
  }
}

# Ensure output directory exists
$parent = Split-Path -Parent $OutputWkp
if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

Write-Host "Building Bengaluru WKP..."
if ($UseOverpass) {
  Write-Host "  Input : Overpass (network)"
} else {
  Write-Host "  Input : $InputPbf"
}
Write-Host "  Output: $OutputWkp"
Write-Host "  Bbox  : $Bbox"

if ($UseOverpass) {
  $cachePath = Join-Path $PSScriptRoot "osm_data/bengaluru_overpass.json"
  $highwayRegex = "motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|residential|living_street|unclassified"
  Run-Python @((Join-Path $PSScriptRoot "overpass_to_wkp.py"), $OutputWkp, "--bbox=$Bbox", "--cache=$cachePath", "--tiles=$OverpassTiles", "--highway-regex=$highwayRegex")
} else {
  Run-Python @((Join-Path $PSScriptRoot "osm_preprocessor.py"), $InputPbf, $OutputWkp, "--bbox=$Bbox")
}
if ($LASTEXITCODE -ne 0) {
  if ($UseOverpass) {
    throw "overpass_to_wkp.py failed with exit code $LASTEXITCODE"
  }
  throw "osm_preprocessor.py failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path $OutputWkp)) {
  throw "Output was not created: $OutputWkp"
}

$size = (Get-Item $OutputWkp).Length
if ($size -lt 1024) {
  throw "Output looks too small ($size bytes): $OutputWkp"
}

Write-Host "Done. Generated: $OutputWkp ($size bytes)"