<# : ---- arranque (no tocar): abre la ventana del programa sin consola ----
@echo off
set "CN_ROOT=%~dp0"
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "try { iex ((Get-Content -LiteralPath '%~f0' -Raw)) } catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('No se pudo abrir el generador:' + [char]10 + [char]10 + $_.Exception.Message + [char]10 + 'linea ' + $_.InvocationInfo.ScriptLineNumber, 'Generador de cortes') }"
goto :eof
#>
# =====================================================================
#  GENERADOR_DE_CORTES.bat  -  Quinta Heeren  (doble clic: se abre una ventana)
#
#  0. (opcional) Si tu nube esta en .las: boton "Convertir .las a .rcs" (abre ReCap) y "Vincular nube en Revit".
#  EN REVIT: por cada corte haz DOS secciones sobre la misma linea:
#     - una corta (p. ej. 10 cm de profundidad, la nube en rojo) = la LINEA DE CORTE
#     - otra larga (hasta el fondo)                               = la vista CON FONDO
#  El complemento "Cortes nube" (se instala solo la primera vez) avisa en vivo a esta ventana.
#  EN ESTA VENTANA: los cortes aparecen solos; pulsa GENERAR CORTES y pon el nombre de cada corte.
#  RESULTADO: CORTES DWG\Corte <nombre>.dwg  (escala real, independiente) con 2 imagenes:
#     arriba  = vista con fondo + la linea de corte en rojo encima
#     abajo   = solo la seccion de corte en rojo
#  y TIFF\ con esas 2 imagenes georreferenciadas.
# =====================================================================
# ----------------------------- AJUSTES (normalmente no hace falta tocar) ---------
$NUBE           = ''            # '' = la nube .bin mas grande de $CARPETA_NUBE
$CARPETA_NUBE   = '..\b4 final limpia v2'
$PPP            = 600           # calidad por defecto de los TIFF: puntos por pulgada al imprimir...
$ESCALA         = 50            # ...a esta escala (1:50). 600 ppp a 1:50 = pixel de 2.1 mm. Se cambia en la ventana.
$REVIT_MINIMO   = 2023          # version minima de Revit
$RELLENO        = 0.02          # m. rellena huecos entre puntos menores a esto
$Z_TOPE_MIN     = -1.0          # m. las imagenes no bajan de esta cota aunque la seccion de Revit sea mas alta
$Z_TOPE_MAX     = 15.0          # m. ni suben de esta
$ROJO_MAX       = 1.0           # m. una seccion hasta esta profundidad se toma como "linea de corte"
$ROJO_AUTO      = 0.10          # m. si solo hay una seccion larga, la linea de corte se saca con esta profundidad
$MAX_PX         = 2000          # lado maximo de cada pedazo OLE. NO subir.
$BAJA           = 12.0          # m. la fila "solo seccion" va esta distancia debajo de la fila "con fondo"
$SEPARACION     = 5.0
$CLOUDCOMPARE   = 'C:\Program Files\CloudCompare\CloudCompare.exe'
# =================================================================================
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()
try {
Add-Type -TypeDefinition @'
