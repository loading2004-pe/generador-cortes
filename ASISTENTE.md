# Reglas para el asistente automático (Generador de cortes)

App de Favio (arquitecto, Lima): Revit (secciones) + nube de puntos -> TIFF -> DWG a escala real en AutoCAD.
El usuario habla español; todas las respuestas y textos de la app en español sencillo.

## Dónde está todo
- Código fuente: `fuente/` (PowerShell + C#). `bash fuente/build.sh` arma `GENERADOR_DE_CORTES.bat` (requiere `mcs` de mono:
  `apt-get install -y mono-mcs` si falta). NUNCA editar el .bat a mano: editar `fuente/` y reconstruir.
  - `fuente/app2_head.ps1` + C# (`CNPrep.cs`, `CNTif.cs`, `CNRev.cs`, `CNBg.cs`, `CNSec.cs`) + `fuente/app2_body.ps1` (interfaz).
  - `fuente/addin/CortesNube.cs` (complemento de Revit; cambiarlo obliga a reabrir Revit) y `CortesNubeMotor.cs`
    (motor; se recarga solo con Revit abierto). `stub.cs` = API de Revit falsa solo para compilar en Linux.
- Publicar: `python3 publicar.py --notas "qué cambió (para el usuario)"` (sube versión, commit y push). Las PCs
  la reciben al abrir GeneradorCortes.exe (ventana «Hay una actualización disponible»).
- `lanzador/` = el .exe (no tocar salvo que sea imprescindible; si cambia hay que repartir el .exe a mano).
- En la PC del usuario: `C:\Users\User\Downloads\prueba 2\` (GeneradorCortes.exe, `asistente\`, `TIFF\`, `CORTES DWG\`).
  - `asistente\pedidos.jsonl`: pedidos del usuario (uno por línea: id, fecha, pedido, urgente).
  - `asistente\respuestas.jsonl`: TUS respuestas (una línea JSON por respuesta: {"id": <id del pedido o "">,
    "fecha": "AAAA-MM-DD HH:MM", "estado": "hecho" | "en curso" | "necesito datos" | "no se puede", "respuesta": "..."}).
    El programa las muestra al abrirse. Responde SIEMPRE cada pedido nuevo.
  - `asistente\registro.log`: registro de la app (busca "ERROR", "Error", excepciones).

## Reglas
- PowerShell 5.1: el .bat debe ser ASCII (sin tildes ni ñ en el código; el build avisa).
- Probar antes de publicar: el build debe compilar sin errores; si tocas lógica, prueba lo que puedas en Linux.
  Si no puedes probar algo de forma segura, NO publiques: responde "necesito datos" explicando qué falta.
- No borrar archivos del usuario. No cambiar la calidad/escala por defecto sin que el usuario lo pida.
- Hechos verificados (no romper): TIFF exportados de Revit no traen escala (la app pregunta ppp + 1:N);
  piezas OLE <= 2000 px agrupadas por fila (OLEFRAME 2, DisplayOLEScale false); GetPoints numPoints < 1 000 000.
- Un cambio pequeño y seguro por pedido; notas de versión claras para el usuario.
