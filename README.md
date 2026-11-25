# Generador de cortes (Quinta Heeren)

Secciones de Revit + nube de puntos -> TIFF y DWG a escala real.

La app `GeneradorCortes.exe` descarga de aqui sus actualizaciones (`version.json` + `GENERADOR_DE_CORTES.bat`)
cada vez que se abre: si hay una version nueva aparece una ventana con el boton **Actualizar**.

Publicar una version nueva: `python publicar.py --notas "que cambio"`.

`lanzador/`: codigo del .exe (Lanzador.cs + arranque.ps1 + icono.ico). Solo hay que recompilarlo si cambia el arranque.
