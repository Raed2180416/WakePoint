$file = "D:\GeoWake\lib\services\trackingservice.dart"
$lines = Get-Content $file

# Define ranges (0-indexed in array, 1-indexed in editor)
# Extension starts at 1327 (index 1326)
# Extension ends at 1824 (index 1823) - based on Step 1649 showing line 1824 as '}'
# Methods are inside.

# Find the line with "extension TrackingServiceRouteOps"
$extStart = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "extension TrackingServiceRouteOps") {
        $extStart = $i
        break
    }
}

# Corrected null comparison
if ($null -eq $extStart) {
    Write-Host "Extension not found"
    exit 1
}

# Find the end of the file (or the last closing brace)
$extEnd = $lines.Count - 1
# Verify it is '}'
if ($lines[$extEnd].Trim() -ne "}") {
    # Maybe empty lines at end
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Trim() -eq "}") {
            $extEnd = $i
            break
        }
    }
}

Write-Host "Extension found at $extStart to $extEnd"

# Extract methods (exclude extension declaration and closing brace)
$methods = $lines[($extStart + 1)..($extEnd - 1)]

# Remove the extension block from the original lines
# We need to reconstruct the file
$beforeExt = $lines[0..($extStart - 1)]
$afterExt = $lines[($extEnd + 1)..($lines.Count - 1)] # Likely empty or just newlines

# Now insert methods into TrackingService class
# Find the end of TrackingService class (line 292, index 291)
$classEnd = $null
for ($i = 0; $i -lt $beforeExt.Count; $i++) {
    if ($lines[$i] -match "^\}") {
        # Check context: previous lines should be getters
        if ($lines[$i - 1] -match "get lastValidPosition") {
            $classEnd = $i
            break
        }
    }
}

# Corrected null comparison
if ($null -eq $classEnd) {
    Write-Host "Class end not found"
    exit 1
}

Write-Host "Class end found at $classEnd"

# Construct new content
$newContent = @()
$newContent += $lines[0..($classEnd - 1)]
$newContent += $methods
$newContent += $lines[$classEnd] # The closing brace of the class
$newContent += $lines[($classEnd + 1)..($extStart - 1)] # The content between class end and extension start (top-level stuff)
$newContent += $afterExt

$newContent | Set-Content $file -Encoding UTF8
Write-Host "Done"
