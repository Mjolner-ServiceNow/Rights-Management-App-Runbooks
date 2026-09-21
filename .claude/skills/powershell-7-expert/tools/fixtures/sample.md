# Fixture for Test-SkillExample.ps1

A correct block. The validator must accept it.

```powershell
# RIGHT
$path = Join-Path -Path $HOME -ChildPath 'logs' -AdditionalChildPath 'run.log'
Write-Verbose "Writing to $path"
```

A block with a parse error, marked WRONG. The validator must SKIP it.

```powershell
# WRONG
if ($true {
```

A block with a parse error and no marker. The validator must REJECT it.

```powershell
$broken = @{
```

A non-PowerShell block. The validator must ignore it.

```bash
echo "not powershell"
```
