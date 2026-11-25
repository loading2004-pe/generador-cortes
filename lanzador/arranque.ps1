# Generador de cortes - arranque con actualizacion automatica (lo abre GeneradorCortes.exe)
# 1) mira en GitHub si hay una version mas nueva del programa (version.json + GENERADOR_DE_CORTES.bat)
# 2) si la hay, pregunta: [Actualizar] [Mas tarde]; descarga, comprueba sha256 y la guarda
# 3) abre la version mas nueva que tenga (descargada o la incluida en el .exe)
# Si la version descargada falla al abrir, se marca como mala y se abre la incluida.
param([switch]$SinActualizar)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$DATOS    = $env:CN_DATA
$LANZADOR = [int]$env:CN_LANZADOR
$URL      = 'https://raw.githubusercontent.com/loading2004-pe/generador-cortes/main/'
$PROGRAMA = 'GENERADOR_DE_CORTES.bat'
$Codigo   = Join-Path $DATOS 'codigo'
$Incluido = Join-Path $DATOS 'incluido'
$LogAct   = Join-Path $DATOS 'actualizaciones.log'
$Malas    = Join-Path $DATOS 'versiones_malas.txt'

function Anotar([string]$m) { try { Add-Content -LiteralPath $LogAct -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss ') + $m) } catch {} }
function Clave($v) { $p = @(([string]$v) -split '[.\-]' | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n }); while ($p.Count -lt 4) { $p += 0 }; '{0:D5}{1:D3}{2:D3}{3:D5}' -f $p[0], $p[1], $p[2], $p[3] }
function LeerVersion($dir) { try { Get-Content -LiteralPath (Join-Path $dir 'version.json') -Raw | ConvertFrom-Json } catch { $null } }
function VersionesMalas { if (Test-Path -LiteralPath $Malas) { @(Get-Content -LiteralPath $Malas) } else { @() } }
function Sha256([byte[]]$b) { $h = [System.Security.Cryptography.SHA256]::Create(); ([BitConverter]::ToString($h.ComputeHash($b)) -replace '-', '').ToLower() }

# configuracion opcional: %LOCALAPPDATA%\GeneradorCortes\config.json  {"url_actualizaciones": "...", "actualizar_auto": true}
$cfg = $null; try { $cfg = Get-Content -LiteralPath (Join-Path $DATOS 'config.json') -Raw | ConvertFrom-Json } catch {}
if ($cfg -and $cfg.url_actualizaciones) { $URL = [string]$cfg.url_actualizaciones; if (-not $URL.EndsWith('/') -and -not $URL.EndsWith('\')) { $URL += '/' } }
$auto = -not ($cfg -and $cfg.PSObject.Properties['actualizar_auto'] -and -not $cfg.actualizar_auto)

function Leer([string]$nombre, [int]$seg) {
  if ($URL -match '^https?://') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = [Net.HttpWebRequest]::Create($URL + [Uri]::EscapeDataString($nombre) + '?t=' + [DateTime]::UtcNow.Ticks)
    $r.Timeout = $seg * 1000; $r.ReadWriteTimeout = $seg * 1000; $r.UserAgent = 'GeneradorCortes'
    $r.Headers['Cache-Control'] = 'no-cache'
    $resp = $r.GetResponse(); $ms = New-Object IO.MemoryStream
    try { $resp.GetResponseStream().CopyTo($ms) } finally { $resp.Close() }
    return ,$ms.ToArray()
  }
  return ,[IO.File]::ReadAllBytes((Join-Path $URL $nombre))
}

function Preguntar($man) {
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'Generador de cortes - actualizacion'; $f.TopMost = $true; $f.StartPosition = 'CenterScreen'
  $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $f.Font = New-Object System.Drawing.Font('Segoe UI', 10); $f.ClientSize = New-Object System.Drawing.Size(460, 210)
  $t = New-Object System.Windows.Forms.Label; $t.Text = 'Hay una actualizacion disponible'; $t.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
  $t.SetBounds(18, 14, 430, 28); $f.Controls.Add($t)
  $v = New-Object System.Windows.Forms.Label; $v.Text = "Version $($man.version)"; $v.ForeColor = [System.Drawing.Color]::FromArgb(31, 95, 168); $v.SetBounds(18, 44, 430, 22); $f.Controls.Add($v)
  $n = New-Object System.Windows.Forms.TextBox; $n.Multiline = $true; $n.ReadOnly = $true; $n.BorderStyle = 'None'; $n.BackColor = $f.BackColor
  $n.ScrollBars = 'Vertical'; $n.Text = [string]$man.notas; $n.SetBounds(18, 70, 425, 86); $f.Controls.Add($n)
  $si = New-Object System.Windows.Forms.Button; $si.Text = 'Actualizar'; $si.SetBounds(335, 166, 108, 32); $si.DialogResult = 'Yes'; $f.Controls.Add($si)
  $no = New-Object System.Windows.Forms.Button; $no.Text = 'Mas tarde'; $no.SetBounds(220, 166, 108, 32); $no.DialogResult = 'No'; $f.Controls.Add($no)
  $f.AcceptButton = $si; $f.CancelButton = $no
  $f.Add_Shown({ $f.Activate() })
  return ($f.ShowDialog() -eq 'Yes')
}

function Descargar($man) {
  $tmp = "$Codigo" + '_nuevo'
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  foreach ($p in $man.archivos.PSObject.Properties) {
    $nom = $p.Name
    if ($nom -match '[\\/]' -or $nom.StartsWith('.')) { throw "nombre de archivo no permitido: $nom" }
    $b = Leer $nom 60
    if ((Sha256 $b) -ne ([string]$p.Value).ToLower()) { throw "$nom : la descarga no coincide (sha256)" }
    [IO.File]::WriteAllBytes((Join-Path $tmp $nom), $b)
  }
  ($man | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $tmp 'version.json') -Encoding UTF8
  $ant = "$Codigo" + '_anterior'
  if (Test-Path -LiteralPath $ant) { Remove-Item -LiteralPath $ant -Recurse -Force }
  if (Test-Path -LiteralPath $Codigo) { Rename-Item -LiteralPath $Codigo -NewName (Split-Path $ant -Leaf) }
  Rename-Item -LiteralPath $tmp -NewName (Split-Path $Codigo -Leaf)
}

Anotar "inicio (lanzador $LANZADOR, datos $DATOS)"
$msg = ''
if (-not $SinActualizar -and $auto) {
  try {
    $man = [Text.Encoding]::UTF8.GetString((Leer 'version.json' 5)) | ConvertFrom-Json
    $loc = LeerVersion $Codigo; $inc = LeerVersion $Incluido
    $actual = @((Clave $(if ($inc) { $inc.version } else { '0' })), (Clave $(if ($loc) { $loc.version } else { '0' }))) | Sort-Object | Select-Object -Last 1
    if ((Clave $man.version) -le $actual) { $msg = "ya tienes la ultima version ($($man.version))" }
    elseif ((VersionesMalas) -contains $man.version) { $msg = "la version $($man.version) fallo antes en esta PC; se omite" }
    elseif ([int]$man.min_lanzador -gt $LANZADOR) { $msg = "la version $($man.version) necesita un GeneradorCortes.exe nuevo" }
    elseif (Preguntar $man) {
      try { Descargar $man; $msg = "descargada la version $($man.version)" }
      catch { $msg = "no se pudo descargar la version $($man.version): $($_.Exception.Message)"; [System.Windows.Forms.MessageBox]::Show("No se pudo descargar la actualizacion:`n$($_.Exception.Message)`n`nSe abre la version que ya tienes.", 'Generador de cortes', 'OK', 'Warning') | Out-Null }
    } else { $msg = "version $($man.version) disponible (pospuesta)" }
  } catch { $msg = "sin conexion con el servidor de actualizaciones ($($_.Exception.Message))" }
  Anotar $msg
}

# elegir la version a abrir: la descargada si es mas nueva que la incluida y no esta marcada como mala
$loc = LeerVersion $Codigo; $inc = LeerVersion $Incluido
$usar = $Incluido; $ver = if ($inc) { $inc.version } else { '?' }
if ($loc -and (Test-Path -LiteralPath (Join-Path $Codigo $PROGRAMA)) -and (Clave $loc.version) -gt (Clave $ver) -and -not ((VersionesMalas) -contains $loc.version)) { $usar = $Codigo; $ver = $loc.version }
$env:CN_VERSION = $ver
$env:CN_UPDATE_MSG = $msg
$ErrorActionPreference = 'Continue'

try {
  iex ((Get-Content -LiteralPath (Join-Path $usar $PROGRAMA) -Raw))
} catch {
  $err = "$($_.Exception.Message) (linea $($_.InvocationInfo.ScriptLineNumber))"
  Anotar "ERROR al abrir la version $ver : $err"
  if ($usar -eq $Codigo) {
    Add-Content -LiteralPath $Malas -Value $ver
    [System.Windows.Forms.MessageBox]::Show("La version $ver fallo al abrir:`n$err`n`nSe abre la version incluida en el programa.", 'Generador de cortes', 'OK', 'Warning') | Out-Null
    $env:CN_VERSION = if ($inc) { $inc.version } else { '?' }
    iex ((Get-Content -LiteralPath (Join-Path $Incluido $PROGRAMA) -Raw))
  } else {
    [System.Windows.Forms.MessageBox]::Show("No se pudo abrir el generador:`n$err", 'Generador de cortes', 'OK', 'Error') | Out-Null
  }
}
