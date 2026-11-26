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
using System;
using System.IO;
using System.IO.Compression;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;
using System.Globalization;

// Prepara las imagenes de CloudCompare (GeoTIFF) para pegarlas en AutoCAD como OLE:
//  - lee el TIFF (sin comprimir, PackBits, LZW o Deflate; RGB o RGBA; normal o BigTIFF)
//  - recorta el borde vacio, pone fondo BLANCO y reduce el pixel al tamano pedido
//  - corta en pedazos de maximo N x N pixeles y los guarda como PNG
//  - devuelve la posicion real (metros) de cada pedazo: U = horizontal de la vista, Z = altura
// Escrito en C# 5 para que lo compile Windows PowerShell 5.1 (Add-Type).
public static class CNPrep
{
    public class Tif
    {
        public int W, H, Spp = 1, Bps = 8, Rps = int.MaxValue, Comp = 1, Planar = 1, Pred = 1, Extra = 0;
        public long[] Off, Cnt;
        public bool Big, Le = true, Geo, Tiled;
        public double Sx, Sy, U0, V0, Dpi;
        public int ResUnit = 2;
        public string Path;
    }
    // TIFF sin georreferencia (p. ej. exportado de otro programa): escala con sus ppp y esta escala (1:Escala);
    // si tampoco trae ppp, se usa PxSinGeo (m por pixel). Origen en (0,0) = esquina inferior izquierda.
    public static double Escala = 50, PxSinGeo = 0;
    public static List<string> SinGeo = new List<string>();
    static double Racional(FileStream fs, Tif t, byte[] e, int vo, int vlen)
    {
        byte[] d;
        if (vlen >= 8) { d = new byte[8]; Array.Copy(e, vo, d, 0, 8); }
        else { long at = (long)Rd(e, vo, vlen, t.Le); d = ReadAt(fs, at, 8); }
        double num = (double)Rd(d, 0, 4, t.Le), den = (double)Rd(d, 4, 4, t.Le);
        return den > 0 ? num / den : 0;
    }

    public class Tile
    {
        public string File;
        public double U, Zbot, W, H;
        public int Px, Py;
    }

    // ------------------------------------------------------------------ lectura TIFF
    static ulong Rd(byte[] b, int o, int n, bool le)
    {
        ulong v = 0;
        if (le) { for (int i = n - 1; i >= 0; i--) v = (v << 8) | b[o + i]; }
        else { for (int i = 0; i < n; i++) v = (v << 8) | b[o + i]; }
        return v;
    }

    static byte[] ReadAt(FileStream fs, long pos, int n)
    {
        byte[] b = new byte[n];
        fs.Position = pos;
        int o = 0;
        while (o < n) { int r = fs.Read(b, o, n - o); if (r <= 0) throw new Exception("TIFF cortado o danado"); o += r; }
        return b;
    }

    static int TypeSize(int t)
    {
        switch (t) { case 1: case 2: case 6: case 7: return 1; case 3: case 8: return 2; case 4: case 9: case 11: case 13: return 4; case 5: case 10: case 12: case 16: case 17: case 18: return 8; default: return 1; }
    }

    static long[] Values(FileStream fs, Tif t, int type, long cnt, byte[] e, int vo, int vlen)
    {
        int sz = TypeSize(type);
        long total = sz * cnt;
        byte[] data; int o;
        if (total <= vlen) { data = e; o = vo; }
        else { long at = (long)Rd(e, vo, vlen, t.Le); data = ReadAt(fs, at, (int)total); o = 0; }
        long[] r = new long[cnt];
        for (long i = 0; i < cnt; i++) r[i] = (long)Rd(data, o + (int)(i * sz), sz, t.Le);
        return r;
    }

    static double[] Doubles(FileStream fs, Tif t, long cnt, byte[] e, int vo, int vlen)
    {
        long total = 8 * cnt;
        byte[] data; int o;
        if (total <= vlen) { data = e; o = vo; }
        else { long at = (long)Rd(e, vo, vlen, t.Le); data = ReadAt(fs, at, (int)total); o = 0; }
        double[] r = new double[cnt];
        for (long i = 0; i < cnt; i++)
        {
            byte[] d = new byte[8];
            Array.Copy(data, o + (int)(i * 8), d, 0, 8);
            if (t.Le != BitConverter.IsLittleEndian) Array.Reverse(d);
            r[i] = BitConverter.ToDouble(d, 0);
        }
        return r;
    }

    public static Tif ReadInfo(string path)
    {
        Tif t = new Tif(); t.Path = path;
        using (FileStream fs = File.OpenRead(path))
        {
            byte[] h = ReadAt(fs, 0, 16);
            if (h[0] == 0x49 && h[1] == 0x49) t.Le = true;
            else if (h[0] == 0x4D && h[1] == 0x4D) t.Le = false;
            else throw new Exception("No es un archivo TIFF: " + path);
            int ver = (int)Rd(h, 2, 2, t.Le);
            long ifd;
            if (ver == 42) { ifd = (long)Rd(h, 4, 4, t.Le); }
            else if (ver == 43) { t.Big = true; ifd = (long)Rd(h, 8, 8, t.Le); }
            else throw new Exception("TIFF no reconocido: " + path);
            int ne, es, vlen;
            if (t.Big) { ne = (int)Rd(ReadAt(fs, ifd, 8), 0, 8, t.Le); es = 20; vlen = 8; }
            else { ne = (int)Rd(ReadAt(fs, ifd, 2), 0, 2, t.Le); es = 12; vlen = 4; }
            long first = ifd + (t.Big ? 8 : 2);
            byte[] all = ReadAt(fs, first, ne * es);
            for (int k = 0; k < ne; k++)
            {
                byte[] e = new byte[es];
                Array.Copy(all, k * es, e, 0, es);
                int tag = (int)Rd(e, 0, 2, t.Le);
                int type = (int)Rd(e, 2, 2, t.Le);
                long cnt = t.Big ? (long)Rd(e, 4, 8, t.Le) : (long)Rd(e, 4, 4, t.Le);
                int vo = t.Big ? 12 : 8;
                switch (tag)
                {
                    case 256: t.W = (int)Values(fs, t, type, 1, e, vo, vlen)[0]; break;
                    case 257: t.H = (int)Values(fs, t, type, 1, e, vo, vlen)[0]; break;
                    case 258: t.Bps = (int)Values(fs, t, type, cnt, e, vo, vlen)[0]; break;
                    case 259: t.Comp = (int)Values(fs, t, type, 1, e, vo, vlen)[0]; break;
                    case 273: t.Off = Values(fs, t, type, cnt, e, vo, vlen); break;
                    case 277: t.Spp = (int)Values(fs, t, type, 1, e, vo, vlen)[0]; break;
                    case 278: t.Rps = (int)Math.Min(int.MaxValue, Values(fs, t, type, 1, e, vo, vlen)[0]); break;
                    case 279: t.Cnt = Values(fs, t, type, cnt, e, vo, vlen); break;
                    case 284: t.Planar = (int)Values(fs, t, type, 1, e, vo, vlen)[0]; break;
                    case 282: if (type == 5) t.Dpi = Racional(fs, t, e, vo, vlen); break;
                    case 296: t.ResUnit = (int)Values(fs, t, type, 1, e, vo, vlen)[0]; break;
                    case 317: t.Pred = (int)Values(fs, t, type, 1, e, vo, vlen)[0]; break;
                    case 322: case 323: case 324: case 325: t.Tiled = true; break;
                    case 338: t.Extra = (int)cnt; break;
                    case 33550: { double[] d = Doubles(fs, t, cnt, e, vo, vlen); t.Sx = d[0]; t.Sy = d[1]; break; }
                    case 33922: { double[] d = Doubles(fs, t, cnt, e, vo, vlen); t.U0 = d[3]; t.V0 = d[4]; t.Geo = true; break; }
                    case 34264: { double[] d = Doubles(fs, t, cnt, e, vo, vlen); t.Sx = d[0]; t.Sy = -d[5]; t.U0 = d[3]; t.V0 = d[7]; t.Geo = true; break; }
                }
            }
        }
        if (t.Tiled) throw new Exception("TIFF en mosaico (tiles): exportalo de nuevo desde CloudCompare (Raster).");
        if (t.Bps != 8) throw new Exception("El TIFF no es de 8 bits por canal (" + t.Bps + "). En CloudCompare exporta SOLO 'RGB colors' (sin alturas).");
        if (t.Spp < 3) throw new Exception("El TIFF no tiene color RGB. En CloudCompare marca 'Export RGB colors'.");
        if (t.Comp != 1 && t.Comp != 5 && t.Comp != 8 && t.Comp != 32946 && t.Comp != 32773)
            throw new Exception("Compresion TIFF no soportada (" + t.Comp + ").");
        if (!t.Geo || t.Sx <= 0)
        {
            double dpi = t.Dpi > 1 ? (t.ResUnit == 3 ? t.Dpi * 2.54 : t.Dpi) : 0;
            double px = (dpi > 1 && Escala > 0) ? 0.0254 / dpi * Escala : PxSinGeo;
            if (px <= 0) throw new Exception("El TIFF no trae georreferencia ni resolucion (ppp): no se puede saber su escala. " + System.IO.Path.GetFileName(path));
            t.Sx = t.Sy = px; t.U0 = 0; t.V0 = t.H * px; t.Geo = true;
            string av = System.IO.Path.GetFileName(path) + ": sin georreferencia; escala por " + (dpi > 1 ? ((int)Math.Round(dpi)) + " ppp a 1:" + Escala : "pixel elegido") + " = pixel " + (px * 1000).ToString("0.##", CultureInfo.InvariantCulture) + " mm";
            if (!SinGeo.Contains(av)) SinGeo.Add(av);
        }
        if (t.Sy <= 0) t.Sy = t.Sx;
        if (t.Rps > t.H) t.Rps = t.H;
        return t;
    }

    // ------------------------------------------------------------------ descompresion
    static byte[] PackBitsDecode(byte[] s, int need)
    {
        byte[] o = new byte[need]; int i = 0, p = 0;
        while (i < s.Length && p < need)
        {
            int n = (sbyte)s[i++];
            if (n >= 0) { int c = Math.Min(n + 1, need - p); Array.Copy(s, i, o, p, Math.Min(c, s.Length - i)); i += n + 1; p += c; }
            else if (n != -128) { int c = Math.Min(1 - n, need - p); byte v = s[i++]; for (int k = 0; k < c; k++) o[p++] = v; }
        }
        return o;
    }

    static byte[] LzwDecode(byte[] s, int need)
    {
        byte[] o = new byte[need]; int p = 0;
        byte[][] dict = new byte[4096][];
        for (int i = 0; i < 256; i++) dict[i] = new byte[] { (byte)i };
        int next = 258, width = 9; long bitPos = 0; long nbits = (long)s.Length * 8;
        byte[] prev = null;
        while (bitPos + width <= nbits)
        {
            int code = 0;
            for (int b = 0; b < width; b++) { long bp = bitPos + b; code = (code << 1) | ((s[bp >> 3] >> (7 - (int)(bp & 7))) & 1); }
            bitPos += width;
            if (code == 257) break;
            if (code == 256) { next = 258; width = 9; prev = null; continue; }
            byte[] entry;
            if (code < next && dict[code] != null) entry = dict[code];
            else if (prev != null) { entry = new byte[prev.Length + 1]; Array.Copy(prev, entry, prev.Length); entry[prev.Length] = prev[0]; }
            else break;
            int c = Math.Min(entry.Length, need - p); Array.Copy(entry, 0, o, p, c); p += c;
            if (prev != null && next < 4096)
            {
                byte[] ne = new byte[prev.Length + 1]; Array.Copy(prev, ne, prev.Length); ne[prev.Length] = entry[0];
                dict[next++] = ne;
            }
            prev = entry;
            if (next + 1 >= (1 << width) && width < 12) width++;
            if (p >= need) break;
        }
        return o;
    }

    static byte[] InflateDecode(byte[] s, int need)
    {
        byte[] o = new byte[need];
        using (MemoryStream ms = new MemoryStream(s, 2, s.Length - 2))
        using (DeflateStream ds = new DeflateStream(ms, CompressionMode.Decompress))
        {
            int p = 0;
            while (p < need) { int r = ds.Read(o, p, need - p); if (r <= 0) break; p += r; }
        }
        return o;
    }

    // Lector por filas (mantiene en memoria solo el bloque actual)
    public class RowReader : IDisposable
    {
        Tif t; FileStream fs; int curStrip = -1; byte[][] stripBuf; int rowBytes, bands;
        public RowReader(Tif tif)
        {
            t = tif; fs = File.OpenRead(t.Path);
            bands = (t.Planar == 2) ? t.Spp : 1;
            rowBytes = (t.Planar == 2) ? t.W : t.W * t.Spp;
            stripBuf = new byte[bands][];
        }
        byte[] LoadStrip(int idx, int rowsInStrip)
        {
            int need = rowBytes * rowsInStrip;
            long off = t.Off[idx];
            if (t.Comp == 1)
            {
                return ReadAt(fs, off, need);
            }
            long cnt = (t.Cnt != null && idx < t.Cnt.Length) ? t.Cnt[idx] : need;
            byte[] raw = ReadAt(fs, off, (int)cnt);
            byte[] d;
            if (t.Comp == 32773) d = PackBitsDecode(raw, need);
            else if (t.Comp == 5) d = LzwDecode(raw, need);
            else d = InflateDecode(raw, need);
            if (t.Pred == 2)
            {
                int stride = (t.Planar == 2) ? 1 : t.Spp;
                for (int r = 0; r < rowsInStrip; r++)
                {
                    int b0 = r * rowBytes;
                    for (int i = stride; i < rowBytes; i++) d[b0 + i] = (byte)(d[b0 + i] + d[b0 + i - stride]);
                }
            }
            return d;
        }
        // Devuelve la fila y en formato RGBA (4 bytes por pixel)
        public void ReadRow(int y, byte[] rgba)
        {
            int strip = y / t.Rps;
            int stripsPerBand = (t.H + t.Rps - 1) / t.Rps;
            int rowsInStrip = Math.Min(t.Rps, t.H - strip * t.Rps);
            if (strip != curStrip)
            {
                for (int b = 0; b < bands; b++) stripBuf[b] = LoadStrip(strip + b * stripsPerBand, rowsInStrip);
                curStrip = strip;
            }
            int r0 = (y - strip * t.Rps) * rowBytes;
            bool alpha = t.Spp >= 4;
            if (t.Planar == 2)
            {
                byte[] R = stripBuf[0], G = stripBuf[1], B = stripBuf[2], A = alpha ? stripBuf[3] : null;
                for (int x = 0; x < t.W; x++)
                {
                    byte r = R[r0 + x], g = G[r0 + x], bl = B[r0 + x];
                    rgba[4 * x] = r; rgba[4 * x + 1] = g; rgba[4 * x + 2] = bl;
                    rgba[4 * x + 3] = alpha ? A[r0 + x] : (byte)((r | g | bl) == 0 ? 0 : 255);
                }
            }
            else
            {
                byte[] s = stripBuf[0]; int spp = t.Spp;
                for (int x = 0; x < t.W; x++)
                {
                    int a = r0 + x * spp;
                    byte r = s[a], g = s[a + 1], bl = s[a + 2];
                    rgba[4 * x] = r; rgba[4 * x + 1] = g; rgba[4 * x + 2] = bl;
                    rgba[4 * x + 3] = alpha ? s[a + 3] : (byte)((r | g | bl) == 0 ? 0 : 255);
                }
            }
        }
        public void Dispose() { if (fs != null) fs.Dispose(); fs = null; }
    }

    // ------------------------------------------------------------------ PNG (RGB 8 bits)
    static uint[] crcTable;
    static uint Crc(byte[] b, int o, int n, uint c)
    {
        if (crcTable == null)
        {
            crcTable = new uint[256];
            for (uint i = 0; i < 256; i++) { uint v = i; for (int k = 0; k < 8; k++) v = ((v & 1) != 0) ? (0xEDB88320u ^ (v >> 1)) : (v >> 1); crcTable[i] = v; }
        }
        for (int i = 0; i < n; i++) c = crcTable[(c ^ b[o + i]) & 0xFF] ^ (c >> 8);
        return c;
    }

    static void Chunk(Stream s, string type, byte[] data, int len)
    {
        byte[] l = BitConverter.GetBytes(len); if (BitConverter.IsLittleEndian) Array.Reverse(l);
        s.Write(l, 0, 4);
        byte[] ty = Encoding.ASCII.GetBytes(type);
        s.Write(ty, 0, 4);
        if (len > 0) s.Write(data, 0, len);
        uint c = Crc(ty, 0, 4, 0xFFFFFFFFu);
        c = Crc(data, 0, len, c) ^ 0xFFFFFFFFu;
        byte[] cb = BitConverter.GetBytes(c); if (BitConverter.IsLittleEndian) Array.Reverse(cb);
        s.Write(cb, 0, 4);
    }

    public class PngWriter
    {
        string path; int w, h, rows; MemoryStream comp; DeflateStream ds; uint a1 = 1, a2 = 0; byte[] prev, line;
        public PngWriter(string p, int width, int height)
        {
            path = p; w = width; h = height; comp = new MemoryStream();
            ds = new DeflateStream(comp, CompressionLevel.Fastest, true);
            prev = new byte[w * 3]; line = new byte[w * 3 + 1];
        }
        void Adler(byte[] b, int n)
        {
            for (int i = 0; i < n; i++) { a1 = (a1 + b[i]) % 65521; a2 = (a2 + a1) % 65521; }
        }
        // rgb: w*3 bytes. Filtro "Up" (resta la fila anterior)
        public void AddRow(byte[] rgb, int offset)
        {
            line[0] = 2;
            for (int i = 0; i < w * 3; i++) { byte v = rgb[offset + i]; line[i + 1] = (byte)(v - prev[i]); prev[i] = v; }
            ds.Write(line, 0, line.Length); Adler(line, line.Length); rows++;
        }
        public void Close()
        {
            ds.Close();
            using (FileStream f = new FileStream(path, FileMode.Create, FileAccess.Write))
            {
                byte[] sig = { 137, 80, 78, 71, 13, 10, 26, 10 }; f.Write(sig, 0, 8);
                byte[] ih = new byte[13];
                byte[] bw = BitConverter.GetBytes(w), bh = BitConverter.GetBytes(h);
                if (BitConverter.IsLittleEndian) { Array.Reverse(bw); Array.Reverse(bh); }
                Array.Copy(bw, 0, ih, 0, 4); Array.Copy(bh, 0, ih, 4, 4);
                ih[8] = 8; ih[9] = 2; ih[10] = 0; ih[11] = 0; ih[12] = 0;
                Chunk(f, "IHDR", ih, 13);
                byte[] d = comp.ToArray();
                byte[] z = new byte[d.Length + 6];
                z[0] = 0x78; z[1] = 0x01;
                Array.Copy(d, 0, z, 2, d.Length);
                uint ad = (a2 << 16) | a1;
                z[z.Length - 4] = (byte)(ad >> 24); z[z.Length - 3] = (byte)(ad >> 16); z[z.Length - 2] = (byte)(ad >> 8); z[z.Length - 1] = (byte)ad;
                int pos = 0; const int CH = 1 << 20;
                while (pos < z.Length) { int n = Math.Min(CH, z.Length - pos); byte[] part = new byte[n]; Array.Copy(z, pos, part, 0, n); Chunk(f, "IDAT", part, n); pos += n; }
                Chunk(f, "IEND", new byte[0], 0);
            }
            comp.Dispose();
        }
    }

    // ------------------------------------------------------------------ proceso completo
    // src: TIFF de CloudCompare. outDir: carpeta de salida. baseName: nombre base de los PNG.
    // pixelFinal: tamano de pixel deseado (m). maxPx: lado maximo de cada pedazo (px).
    public static Tile[] Prepare(string src, string outDir, string baseName, double pixelFinal, int maxPx)
    {
        Tif t = ReadInfo(src);
        byte[] row = new byte[t.W * 4];
        int x0 = int.MaxValue, x1 = -1, y0 = int.MaxValue, y1 = -1;
        using (RowReader rr = new RowReader(t))
        {
            for (int y = 0; y < t.H; y++)
            {
                rr.ReadRow(y, row);
                int a = -1, b = -1;
                for (int x = 0; x < t.W; x++) if (row[4 * x + 3] != 0) { a = x; break; }
                if (a < 0) continue;
                for (int x = t.W - 1; x >= a; x--) if (row[4 * x + 3] != 0) { b = x; break; }
                if (a < x0) x0 = a; if (b > x1) x1 = b; if (y < y0) y0 = y; y1 = y;
            }
        }
        if (x1 < 0) return new Tile[0];
        int k = (int)Math.Round(pixelFinal / t.Sx); if (k < 1) k = 1;
        int cw = x1 - x0 + 1, ch = y1 - y0 + 1;
        int ow = (cw + k - 1) / k, oh = (ch + k - 1) / k;
        double px = t.Sx * k;
        double uLeft = t.U0 + x0 * t.Sx;
        double zTop = t.V0 - y0 * t.Sy;
        int nx = (ow + maxPx - 1) / maxPx, ny = (oh + maxPx - 1) / maxPx;
        List<Tile> tiles = new List<Tile>();
        Directory.CreateDirectory(outDir);
        long[] acc = new long[ow * 3];
        int[] nacc = new int[ow];
        byte[] outRow = new byte[ow * 3];
        PngWriter[] cur = new PngWriter[nx];
        using (RowReader rr = new RowReader(t))
        {
            for (int oy = 0; oy < oh; oy++)
            {
                int ty = oy / maxPx;
                if (oy % maxPx == 0)
                {
                    int th = Math.Min(maxPx, oh - ty * maxPx);
                    for (int tx = 0; tx < nx; tx++)
                    {
                        int tw = Math.Min(maxPx, ow - tx * maxPx);
                        string suf = (nx * ny == 1) ? "" : ("_p" + (ty * nx + tx + 1));
                        string f = Path.Combine(outDir, baseName + suf + ".png");
                        cur[tx] = new PngWriter(f, tw, th);
                        Tile tl = new Tile();
                        tl.File = f; tl.Px = tw; tl.Py = th;
                        tl.U = uLeft + tx * maxPx * px; tl.W = tw * px; tl.H = th * px;
                        tl.Zbot = zTop - (ty * maxPx + th) * px;
                        tiles.Add(tl);
                    }
                }
                Array.Clear(acc, 0, acc.Length); Array.Clear(nacc, 0, nacc.Length);
                for (int sy = 0; sy < k; sy++)
                {
                    int y = y0 + oy * k + sy;
                    if (y > y1) { for (int ox = 0; ox < ow; ox++) { acc[3 * ox] += 255 * k; acc[3 * ox + 1] += 255 * k; acc[3 * ox + 2] += 255 * k; nacc[ox] += k; } continue; }
                    rr.ReadRow(y, row);
                    for (int ox = 0; ox < ow; ox++)
                    {
                        for (int sx = 0; sx < k; sx++)
                        {
                            int x = x0 + ox * k + sx;
                            if (x > x1) { acc[3 * ox] += 255; acc[3 * ox + 1] += 255; acc[3 * ox + 2] += 255; }
                            else
                            {
                                int p = 4 * x; int al = row[p + 3];
                                if (al == 255) { acc[3 * ox] += row[p]; acc[3 * ox + 1] += row[p + 1]; acc[3 * ox + 2] += row[p + 2]; }
                                else if (al == 0) { acc[3 * ox] += 255; acc[3 * ox + 1] += 255; acc[3 * ox + 2] += 255; }
                                else
                                {
                                    acc[3 * ox] += (row[p] * al + 255 * (255 - al)) / 255;
                                    acc[3 * ox + 1] += (row[p + 1] * al + 255 * (255 - al)) / 255;
                                    acc[3 * ox + 2] += (row[p + 2] * al + 255 * (255 - al)) / 255;
                                }
                            }
                            nacc[ox]++;
                        }
                    }
                }
                for (int ox = 0; ox < ow; ox++)
                {
                    int n = nacc[ox];
                    outRow[3 * ox] = (byte)((acc[3 * ox] + n / 2) / n);
                    outRow[3 * ox + 1] = (byte)((acc[3 * ox + 1] + n / 2) / n);
                    outRow[3 * ox + 2] = (byte)((acc[3 * ox + 2] + n / 2) / n);
                }
                for (int tx = 0; tx < nx; tx++) cur[tx].AddRow(outRow, tx * maxPx * 3);
                if (oy % maxPx == maxPx - 1 || oy == oh - 1)
                    for (int tx = 0; tx < nx; tx++) { cur[tx].Close(); cur[tx] = null; }
            }
        }
        return tiles.ToArray();
    }

    // ------------------------------------------------------------------ armado de los DWG
    public class Img { public string Path, Name, Letter, View, Kind; }

    static string F4(double v) { return v.ToString("0.0000", CultureInfo.InvariantCulture); }
    static string Lsp(string p) { return p.Replace('\\', '/').Replace("\"", "\\\""); }

    public const string CLIP_PS1 =
"# Pone una imagen en el portapapeles como Enhanced Metafile (AutoCAD la pega como OLE 'Picture'\r\n" +
"# que queda DENTRO del DWG y se ve en cualquier PC, sin archivos externos)\r\n" +
"Add-Type -AssemblyName System.Drawing\r\n" +
"Add-Type -TypeDefinition @\"\r\n" +
"using System; using System.Runtime.InteropServices;\r\n" +
"public static class CNClip {\r\n" +
"  [DllImport(\"user32.dll\")] static extern bool OpenClipboard(IntPtr h);\r\n" +
"  [DllImport(\"user32.dll\")] static extern bool EmptyClipboard();\r\n" +
"  [DllImport(\"user32.dll\")] static extern IntPtr SetClipboardData(uint f, IntPtr h);\r\n" +
"  [DllImport(\"user32.dll\")] static extern bool CloseClipboard();\r\n" +
"  [DllImport(\"user32.dll\")] public static extern bool SetProcessDPIAware();\r\n" +
"  public static bool SetEmf(IntPtr h) {\r\n" +
"    for (int i = 0; i < 20 && !OpenClipboard(IntPtr.Zero); i++) System.Threading.Thread.Sleep(100);\r\n" +
"    EmptyClipboard(); IntPtr r = SetClipboardData(14, h); CloseClipboard(); return r != IntPtr.Zero;\r\n" +
"  }\r\n" +
"}\r\n" +
"\"@\r\n" +
"$src = [System.Drawing.Image]::FromFile($args[0])\r\n" +
"$bmp = New-Object System.Drawing.Bitmap($src.Width, $src.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)\r\n" +
"$gb = [System.Drawing.Graphics]::FromImage($bmp); $gb.Clear([System.Drawing.Color]::White); $gb.DrawImage($src, 0, 0, $src.Width, $src.Height); $gb.Dispose(); $src.Dispose()\r\n" +
"[void][CNClip]::SetProcessDPIAware()\r\n" +
"$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $hdc = $g0.GetHdc()\r\n" +
"$rect = New-Object System.Drawing.RectangleF(0, 0, $bmp.Width, $bmp.Height)\r\n" +
"$mf = New-Object System.Drawing.Imaging.Metafile($hdc, $rect, [System.Drawing.Imaging.MetafileFrameUnit]::Pixel, [System.Drawing.Imaging.EmfType]::EmfOnly)\r\n" +
"$g0.ReleaseHdc($hdc); $g0.Dispose()\r\n" +
"$g = [System.Drawing.Graphics]::FromImage($mf); $g.PageUnit = [System.Drawing.GraphicsUnit]::Pixel\r\n" +
"$g.DrawImage($bmp, 0, 0, $bmp.Width, $bmp.Height)\r\n" +
"$g.Dispose()\r\n" +
"$h = $mf.GetHenhmetafile()\r\n" +
"[void][CNClip]::SetEmf($h)\r\n" +
"$bmp.Dispose()\r\n";

    public static List<Img> Find(string imgDir)
    {
        Regex rx = new Regex(@"^Corte_(.+)_(mira[+-][XY]|lado[AB]|revit)_(franja10cm|fondo|conjunto|rojo)$", RegexOptions.IgnoreCase);
        List<Img> r = new List<Img>();
        if (!Directory.Exists(imgDir)) return r;
        foreach (string f in Directory.GetFiles(imgDir))
        {
            string ext = Path.GetExtension(f).ToLowerInvariant();
            if (ext != ".tif" && ext != ".tiff") continue;
            string n = Path.GetFileNameWithoutExtension(f);
            Match m = rx.Match(n);
            if (!m.Success) { Console.WriteLine("  (se ignora, nombre no reconocido) " + Path.GetFileName(f)); continue; }
            Img i = new Img();
            i.Path = f; i.Name = n;
            string nom = m.Groups[1].Value;
            // A, B1, B2... -> se juntan por letra (corte quebrado). Otros nombres (Revit) -> un DWG por nombre.
            i.Letter = (Regex.IsMatch(nom, @"^[A-Za-z]\d*$") && m.Groups[2].Value.ToLowerInvariant() != "revit") ? nom.Substring(0, 1).ToUpperInvariant() : nom;
            string v = m.Groups[2].Value;
            if (v.ToLowerInvariant() == "revit") i.View = "revit";
            else if (v.ToLowerInvariant().StartsWith("lado")) i.View = "lado" + v.Substring(4, 1).ToUpperInvariant();
            else i.View = "mira" + v.Substring(4, 1) + v.Substring(5, 1).ToUpperInvariant();
            i.Kind = m.Groups[3].Value.ToLowerInvariant();
            if (i.Kind == "conjunto") i.Kind = "franja10cm";   // fila de arriba: con fondo + linea de corte
            else if (i.Kind == "rojo") i.Kind = "fondo";       // fila de abajo: solo la seccion en rojo
            r.Add(i);
        }
        r.Sort(delegate (Img a, Img b) { return string.CompareOrdinal(a.Name.ToUpperInvariant(), b.Name.ToUpperInvariant()); });
        return r;
    }

    // Prepara (o reutiliza si no cambio) las imagenes PNG de un TIFF
    static Tile[] PrepareCached(Img im, string pngDir, double px, int maxPx)
    {
        FileInfo fi = new FileInfo(im.Path);
        string key = fi.Length + "|" + fi.LastWriteTimeUtc.Ticks + "|" + px.ToString("R", CultureInfo.InvariantCulture) + "|" + maxPx;
        string side = Path.Combine(pngDir, im.Name + ".info.txt");
        if (File.Exists(side))
        {
            string[] L = File.ReadAllLines(side);
            if (L.Length >= 1 && L[0] == key)
            {
                List<Tile> c = new List<Tile>(); bool ok = true;
                for (int i = 1; i < L.Length; i++)
                {
                    string[] p = L[i].Split('|'); if (p.Length < 7) continue;
                    Tile t = new Tile();
                    t.File = Path.Combine(pngDir, p[0]);
                    t.U = double.Parse(p[1], CultureInfo.InvariantCulture); t.Zbot = double.Parse(p[2], CultureInfo.InvariantCulture);
                    t.W = double.Parse(p[3], CultureInfo.InvariantCulture); t.H = double.Parse(p[4], CultureInfo.InvariantCulture);
                    t.Px = int.Parse(p[5]); t.Py = int.Parse(p[6]);
                    if (!File.Exists(t.File)) ok = false;
                    c.Add(t);
                }
                if (ok) return c.ToArray();
            }
        }
        foreach (string old in Directory.GetFiles(pngDir, im.Name + "*.png"))
        {
            string b = Path.GetFileNameWithoutExtension(old);
            if (b == im.Name || Regex.IsMatch(b.Substring(im.Name.Length), @"^_p\d+$")) File.Delete(old);
        }
        Tile[] ts = Prepare(im.Path, pngDir, im.Name, px, maxPx);
        List<string> o = new List<string>(); o.Add(key);
        foreach (Tile t in ts)
            o.Add(Path.GetFileName(t.File) + "|" + t.U.ToString("R", CultureInfo.InvariantCulture) + "|" + t.Zbot.ToString("R", CultureInfo.InvariantCulture) + "|" +
                  t.W.ToString("R", CultureInfo.InvariantCulture) + "|" + t.H.ToString("R", CultureInfo.InvariantCulture) + "|" + t.Px + "|" + t.Py);
        File.WriteAllLines(side, o.ToArray());
        return ts;
    }

    static List<Tile> Pick(Dictionary<Img, Tile[]> all, string view, string kind)
    {
        List<Tile> r = new List<Tile>();
        foreach (KeyValuePair<Img, Tile[]> kv in all) if (kv.Key.View == view && kv.Key.Kind == kind) r.AddRange(kv.Value);
        r.Sort(delegate (Tile a, Tile b) { return string.CompareOrdinal(Path.GetFileName(a.File), Path.GetFileName(b.File)); });
        return r;
    }

    // Arma los guiones de AutoCAD (uno por letra). Devuelve las letras listas para armar.
    public static string[] Build(string root, string imgDir, string pngDir, double pxFranja, double pxFondo, int maxPx,
                                 double baja, double sep, string solo, string dwgDir)
    {
        Directory.CreateDirectory(pngDir);
        string clip = Path.Combine(pngDir, "clip_emf.ps1");
        File.WriteAllText(clip, CLIP_PS1, Encoding.ASCII);
        List<Img> imgs = Find(imgDir);
        if (imgs.Count == 0) throw new Exception("No hay imagenes Corte_*.tif en " + imgDir);
        List<string> pedidas = new List<string>();
        if (!string.IsNullOrEmpty(solo)) foreach (string s in solo.Split(new char[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)) pedidas.Add(s.Trim().ToUpperInvariant());
        List<string> letras = new List<string>();
        foreach (Img i in imgs) if (!letras.Contains(i.Letter) && (pedidas.Count == 0 || pedidas.Contains(i.Letter.ToUpperInvariant()))) letras.Add(i.Letter);
        letras.Sort(StringComparer.Ordinal);
        List<string> listas = new List<string>();
        foreach (string L in letras)
        {
            Console.WriteLine("  Corte " + L + ": preparando imagenes...");
            Dictionary<Img, Tile[]> all = new Dictionary<Img, Tile[]>();
            foreach (Img i in imgs)
            {
                if (i.Letter != L) continue;
                double px = (i.Kind == "fondo") ? pxFondo : pxFranja;
                Tile[] ts = PrepareCached(i, pngDir, px, maxPx);
                Console.WriteLine("     " + i.Name + "  ->  " + ts.Length + " pedazo(s)");
                if (ts.Length > 0) all[i] = ts;
            }
            if (all.Count == 0) { Console.WriteLine("     (sin imagenes con puntos: se omite)"); continue; }
            bool horiz = false, vert = false;
            bool lados = false, revit = false;
            foreach (Img i in all.Keys) { if (i.View == "revit") revit = true; else if (i.View.StartsWith("lado")) lados = true; else if (i.View.EndsWith("Y")) horiz = true; else vert = true; }
            if ((horiz && vert) || (lados && (horiz || vert)) || (revit && (lados || horiz || vert))) throw new Exception("El corte " + L + " mezcla vistas distintas: revisa los nombres de los TIF.");
            string[] views = revit ? new string[] { "revit" } : lados ? new string[] { "ladoA", "ladoB" } : horiz ? new string[] { "mira+Y", "mira-Y" } : new string[] { "mira+X", "mira-X" };
            string capaArr = revit ? "CORTE_CON_FONDO_Y_LINEA" : "CORTE_SIN_FONDO", capaAba = revit ? "CORTE_SECCION_ROJA" : "CORTE_CON_FONDO";
            string dwg = Path.Combine(dwgDir, "Corte " + L + ".dwg");
            List<string> S = new List<string>();
            List<string> M = new List<string>();
            M.Add("MEDIDAS DEL CORTE " + L + "  (coordenadas en metros dentro de 'Corte " + L + ".dwg')");
            M.Add("Cada imagen se pega con su esquina INFERIOR IZQUIERDA en (X, Y) y con el ancho y alto indicados.");
            M.Add("Y = 0 es el nivel +/-0.00 (Z = 0 de la nube) de la fila 'sin fondo'; la fila 'con fondo' esta " + F4(baja) + " m mas abajo.");
            M.Add("");
            M.Add(string.Format("{0,-44} {1,-16} {2,10} {3,10} {4,9} {5,9}", "IMAGEN", "CAPA", "X", "Y", "ANCHO", "ALTO"));
            S.Add("(vl-load-com)");
            S.Add("(setq doc (vla-get-ActiveDocument (vlax-get-acad-object)) ms (vla-get-ModelSpace doc) sh (vlax-create-object \"WScript.Shell\") cn:os (getvar \"OSMODE\"))");
            S.Add("(setvar \"CMDECHO\" 0) (setvar \"OSMODE\" 0) (setvar \"INSUNITS\" 6) (setvar \"OLEHIDE\" 0) (setvar \"OLEQUALITY\" 3) (setvar \"OLEFRAME\" 2) (setq cn:g1 nil cn:g2 nil) (vl-catch-all-apply (quote vla-put-DisplayOLEScale) (list (vla-get-System (vla-get-Preferences (vlax-get-acad-object))) :vlax-false))");
            S.Add("(defun cn:capa (n c) (if (not (tblsearch \"LAYER\" n)) (command \"_.-LAYER\" \"_N\" n \"_C\" c n \"\")))");
            S.Add("(cn:capa \"" + capaArr + "\" \"7\") (cn:capa \"" + capaAba + "\" \"8\") (cn:capa \"CORTE_NIVEL\" \"1\") (cn:capa \"CORTE_TEXTO\" \"7\")");
            S.Add("(defun cn:ole (png x y w h l / e o mn mx k) (setq e (entlast) k 0) (while (and (< k 6) (equal e (entlast))) (if (> k 0) (command \"_.DELAY\" (* k 800))) (vlax-invoke sh (quote Run) (strcat \"powershell -NoProfile -STA -ExecutionPolicy Bypass -File \\\"\" \"" + Lsp(clip) + "\" \"\\\" \\\"\" png \"\\\"\") 0 :vlax-true) (command \"_.PASTECLIP\" (list x y 0.0)) (setq k (1+ k))) (if (not (equal e (entlast))) (progn (setq o (vlax-ename->vla-object (entlast))) (vla-put-Layer o l) (vl-catch-all-apply (quote vla-put-LockAspectRatio) (list o :vlax-false)) (vla-put-Width o w) (vla-put-Height o h) (vla-GetBoundingBox o (quote mn) (quote mx)) (setq mn (vlax-safearray->list mn)) (vla-Move o (vlax-3d-point mn) (vlax-3d-point (list x y 0.0))) o)))");
            S.Add("(defun cn:mete (o q) (if o (set q (cons o (eval q)))) o)");
            S.Add("(defun cn:grupo (nom lst l / arr r) (if lst (progn (setvar \"PICKSTYLE\" 1) (setq r (vl-catch-all-apply (quote vla-Add) (list (vla-get-Groups doc) nom))) (if (not (vl-catch-all-error-p r)) (progn (setq arr (vlax-make-safearray vlax-vbObject (cons 0 (1- (length lst))))) (vlax-safearray-fill arr lst) (vl-catch-all-apply (quote vla-AppendItems) (list r arr)))))))");
            S.Add("(defun cn:txt (s x y h l / o) (setq o (vla-AddText ms s (vlax-3d-point (list x y 0.0)) h)) (vla-put-Layer o l) o)");
            S.Add("(defun cn:lin (x1 y1 x2 y2 l / o) (setq o (vla-AddLine ms (vlax-3d-point (list x1 y1 0.0)) (vlax-3d-point (list x2 y2 0.0)))) (vla-put-Layer o l) o)");
            double x0 = 0.0;
            foreach (string v in views)
            {
                List<Tile> fr = Pick(all, v, "franja10cm"), fo = Pick(all, v, "fondo");
                if (fr.Count == 0 && fo.Count == 0) continue;
                double umin = double.MaxValue, umax = double.MinValue;
                foreach (Tile t in fr) { umin = Math.Min(umin, t.U); umax = Math.Max(umax, t.U + t.W); }
                foreach (Tile t in fo) { umin = Math.Min(umin, t.U); umax = Math.Max(umax, t.U + t.W); }
                double d = x0 - umin;
                foreach (Tile t in fr)
                {
                    S.Add("(cn:mete (cn:ole \"" + Lsp(t.File) + "\" " + F4(t.U + d) + " " + F4(t.Zbot) + " " + F4(t.W) + " " + F4(t.H) + " \"" + capaArr + "\") (quote cn:g1))");
                    M.Add(string.Format("{0,-44} {1,-16} {2,10} {3,10} {4,9} {5,9}", Path.GetFileName(t.File), capaArr, F4(t.U + d), F4(t.Zbot), F4(t.W), F4(t.H)));
                }
                foreach (Tile t in fo)
                {
                    S.Add("(cn:mete (cn:ole \"" + Lsp(t.File) + "\" " + F4(t.U + d) + " " + F4(t.Zbot - baja) + " " + F4(t.W) + " " + F4(t.H) + " \"" + capaAba + "\") (quote cn:g2))");
                    M.Add(string.Format("{0,-44} {1,-16} {2,10} {3,10} {4,9} {5,9}", Path.GetFileName(t.File), capaAba, F4(t.U + d), F4(t.Zbot - baja), F4(t.W), F4(t.H)));
                }
                double xa = x0, xb = umax + d;
                string lado = v == "ladoA" ? "mirando como la seccion de Revit" : v == "ladoB" ? "mirando al lado contrario" : v.Replace("mira", "hacia ");
                foreach (double yy in new double[] { 0.0, -baja })
                {
                    string gq = ")";
                    S.Add("(progn (cn:lin " + F4(xa - 0.5) + " " + F4(yy) + " " + F4(xb + 0.5) + " " + F4(yy) + " \"CORTE_NIVEL\")" + gq);
                    S.Add("(progn (cn:txt \"N. +/-0.00\" " + F4(xa - 0.5) + " " + F4(yy + 0.05) + " 0.15 \"CORTE_NIVEL\")" + gq);
                }
                if (v == "revit")
                {
                    S.Add("(progn (cn:txt \"corte " + L + " - con fondo y linea de corte\" " + F4(xa) + " -1.2 0.4 \"CORTE_TEXTO\"))");
                    S.Add("(progn (cn:txt \"corte " + L + " - seccion (linea de corte)\" " + F4(xa) + " " + F4(-1.2 - baja) + " 0.4 \"CORTE_TEXTO\"))");
                }
                else
                {
                    S.Add("(cn:txt \"corte " + L + " - sin fondo (franja de 10cm)  (" + lado + ")\" " + F4(xa) + " -1.2 0.4 \"CORTE_TEXTO\")");
                    S.Add("(cn:txt \"corte " + L + " - con fondo  (" + lado + ")\" " + F4(xa) + " " + F4(-1.2 - baja) + " 0.4 \"CORTE_TEXTO\")");
                }
                x0 = xb + sep;
            }
            string gn = Regex.Replace(L, "[^A-Za-z0-9_-]", "_");
            S.Add("(cn:grupo \"CORTE_" + gn + (revit ? "_CON_FONDO_Y_LINEA" : "_SIN_FONDO") + "\" cn:g1 \"" + capaArr + "\")");
            S.Add("(cn:grupo \"CORTE_" + gn + (revit ? "_SECCION_ROJA" : "_CON_FONDO") + "\" cn:g2 \"" + capaAba + "\")");
            S.Add("(command \"_.ZOOM\" \"_E\")");
            S.Add("(setvar \"OSMODE\" cn:os)");
            S.Add("(vla-SaveAs doc \"" + Lsp(dwg) + "\")");
            S.Add("(princ \"\\nCORTE " + L + ": listo.\") (princ)");
            S.Add("_.QUIT");
            S.Add("Y");
            File.WriteAllText(Path.Combine(pngDir, "armar_" + L + ".scr"), string.Join("\n", S.ToArray()) + "\n", Encoding.Default);
            File.WriteAllText(Path.Combine(pngDir, "medidas_Corte_" + L + ".txt"), string.Join("\r\n", M.ToArray()) + "\r\n", Encoding.Default);
            listas.Add(L);
        }
        return listas.ToArray();
    }
}
public static class CNTif {
  public class Info { public int W, H, Spp = 1, Rps = int.MaxValue, Comp = 1; public long[] Off; public double U0, V0, Sx = 0, Sy = 0; }
  public static Info Read(string p) {
    Info i = new Info();
    using (FileStream fs = File.OpenRead(p)) using (BinaryReader br = new BinaryReader(fs)) {
      br.ReadUInt32(); uint ifd = br.ReadUInt32(); fs.Position = ifd; int n = br.ReadUInt16();
      for (int k = 0; k < n; k++) {
        fs.Position = ifd + 2 + 12 * k; int tag = br.ReadUInt16(); int typ = br.ReadUInt16(); uint cnt = br.ReadUInt32(); long vpos = fs.Position;
        long one = (typ == 3) ? (long)br.ReadUInt16() : (long)br.ReadUInt32();
        if (tag == 256) i.W = (int)one; else if (tag == 257) i.H = (int)one; else if (tag == 277) i.Spp = (int)one;
        else if (tag == 278) i.Rps = (int)one; else if (tag == 259) i.Comp = (int)one;
        else if (tag == 273) {
          i.Off = new long[cnt]; int sz = (typ == 3) ? 2 : 4;
          fs.Position = vpos; long at = (cnt * sz > 4) ? (long)br.ReadUInt32() : vpos; fs.Position = at;
          for (int j = 0; j < cnt; j++) i.Off[j] = (typ == 3) ? (long)br.ReadUInt16() : (long)br.ReadUInt32();
        }
        else if (tag == 33922) { fs.Position = vpos; fs.Position = br.ReadUInt32(); double[] t = new double[6]; for (int j = 0; j < 6; j++) t[j] = br.ReadDouble(); i.U0 = t[3]; i.V0 = t[4]; }
        else if (tag == 33550) { fs.Position = vpos; fs.Position = br.ReadUInt32(); i.Sx = br.ReadDouble(); i.Sy = br.ReadDouble(); }
      }
    }
    return i;
  }
  public static void Fill(Stream st, byte[] b) { int o = 0; while (o < b.Length) { int r = st.Read(b, o, b.Length - o); if (r <= 0) break; o += r; } }
  public static void PackBits(byte[] s, int len, MemoryStream o) {
    int i = 0;
    while (i < len) {
      int run = 1; while (i + run < len && run < 128 && s[i + run] == s[i]) run++;
      if (run >= 3) { o.WriteByte((byte)(257 - run)); o.WriteByte(s[i]); i += run; continue; }
      int st = i, lit = 0;
      while (i < len && lit < 128) {
        if (i + 2 < len && s[i] == s[i + 1] && s[i] == s[i + 2]) break;
        i++; lit++;
      }
      o.WriteByte((byte)(lit - 1)); o.Write(s, st, lit);
    }
  }
  // Devuelve el % de pixeles con datos
  public static double ToRgba(string src, string dst, double step, double u0, double v0) {
    Info m = Read(src);
    if (m.Comp != 1) throw new Exception("TIFF de CloudCompare comprimido: no previsto");
    int rps = Math.Min(m.Rps, m.H); long datos = 0;
    long[] offs = new long[m.H]; long[] cnts = new long[m.H];
    using (FileStream fi = File.OpenRead(src)) using (FileStream fo = new FileStream(dst, FileMode.Create, FileAccess.Write)) {
      BinaryWriter bw = new BinaryWriter(fo);
      bw.Write((ushort)0x4949); bw.Write((ushort)42); bw.Write((uint)0);
      byte[] rin = new byte[m.W * m.Spp]; byte[] rout = new byte[m.W * 4]; MemoryStream ms = new MemoryStream(m.W * 4 + 1024);
      for (int y = 0; y < m.H; y++) {
        fi.Position = m.Off[y / rps] + (long)(y % rps) * m.W * m.Spp; Fill(fi, rin);
        for (int x = 0; x < m.W; x++) {
          int a = x * m.Spp, b = x * 4; byte r = rin[a], g = rin[a + 1], bl = rin[a + 2];
          bool vacio = (r == 0 && g == 0 && bl == 0);
          rout[b] = r; rout[b + 1] = g; rout[b + 2] = bl; rout[b + 3] = (byte)(vacio ? 0 : 255);
          if (!vacio) datos++;
        }
        ms.SetLength(0); PackBits(rout, rout.Length, ms);
        offs[y] = fo.Position; cnts[y] = ms.Length; fo.Write(ms.GetBuffer(), 0, (int)ms.Length);
      }
      // datos extra
      long pBits = fo.Position; for (int k = 0; k < 4; k++) bw.Write((ushort)8);
      long pOff = fo.Position; foreach (long v in offs) bw.Write((uint)v);
      long pCnt = fo.Position; foreach (long v in cnts) bw.Write((uint)v);
      long pScale = fo.Position; bw.Write(step); bw.Write(step); bw.Write(0.0);
      long pTie = fo.Position; bw.Write(0.0); bw.Write(0.0); bw.Write(0.0); bw.Write(u0); bw.Write(v0); bw.Write(0.0);
      long pGeo = fo.Position; ushort[] gk = { 1, 1, 0, 2, 1024, 0, 1, 1, 1025, 0, 1, 1 }; foreach (ushort v in gk) bw.Write(v);
      if ((fo.Position & 1) == 1) bw.Write((byte)0);
      long pIfd = fo.Position;
      var tags = new List<uint[]>();
      tags.Add(new uint[] { 256, 4, 1, (uint)m.W });
      tags.Add(new uint[] { 257, 4, 1, (uint)m.H });
      tags.Add(new uint[] { 258, 3, 4, (uint)pBits });
      tags.Add(new uint[] { 259, 3, 1, 32773 });
      tags.Add(new uint[] { 262, 3, 1, 2 });
      tags.Add(new uint[] { 273, 4, (uint)m.H, (uint)pOff });
      tags.Add(new uint[] { 277, 3, 1, 4 });
      tags.Add(new uint[] { 278, 4, 1, 1 });
      tags.Add(new uint[] { 279, 4, (uint)m.H, (uint)pCnt });
      tags.Add(new uint[] { 284, 3, 1, 1 });
      tags.Add(new uint[] { 338, 3, 1, 2 });
      tags.Add(new uint[] { 33550, 12, 3, (uint)pScale });
      tags.Add(new uint[] { 33922, 12, 6, (uint)pTie });
      tags.Add(new uint[] { 34735, 3, 12, (uint)pGeo });
      bw.Write((ushort)tags.Count);
      foreach (uint[] t in tags) {
        bw.Write((ushort)t[0]); bw.Write((ushort)t[1]); bw.Write(t[2]);
        bool inl = (t[1] == 3 && t[2] <= 2 && t[0] != 258 && t[0] != 34735) || (t[1] == 4 && t[2] == 1);
        if (inl && t[1] == 3) { bw.Write((ushort)t[3]); bw.Write((ushort)0); } else bw.Write(t[3]);
      }
      bw.Write((uint)0);
      fo.Position = 4; bw.Write((uint)pIfd); bw.Flush();
    }
    return 100.0 * datos / ((double)m.W * m.H);
  }
}
// ---------------------------------------------------------------------------------
// CNRev: cortes que vienen de secciones de Revit (2 puntos + profundidad del fondo)
//  - lee CORTES_REVIT.txt (lo escribe EXPORTAR_CORTES.dyn)
//  - genera la LINEA ROJA del corte a partir de una rebanada fina de la nube (PLY)
//  - da las cajas y giros para CloudCompare y convierte el raster a RGBA transparente
// ---------------------------------------------------------------------------------
public static class CNRev
{
    static System.Globalization.CultureInfo Inv = System.Globalization.CultureInfo.InvariantCulture;
    public class Corte
    {
        public string Nombre, Fila;
        public double Ax, Ay, Bx, By, Dx, Dy, Fondo, Zmin, Zmax;
        public double Rx { get { return Dy; } }      // derecha de quien mira (D x Z)
        public double Ry { get { return -Dx; } }
        public double P { get { return Dx * Ax + Dy * Ay; } }   // posicion del plano de corte
        public double Largo { get { return System.Math.Sqrt((Bx - Ax) * (Bx - Ax) + (By - Ay) * (By - Ay)); } }
    }

    public static string Limpio(string s)
    {
        foreach (char c in "\\/:*?\"<>|") s = s.Replace(c, '-');
        return s.Trim();
    }

    public static System.Collections.Generic.List<Corte> Leer(string path)
    {
        var r = new System.Collections.Generic.List<Corte>();
        foreach (string raw in System.IO.File.ReadAllLines(path))
        {
            string l = raw.Trim();
            if (l.Length == 0 || l.StartsWith("#") || l.ToLowerInvariant().StartsWith("nombre")) continue;
            string[] p = l.Split(';');
            if (p.Length < 10) throw new System.Exception("Linea mal formada en " + System.IO.Path.GetFileName(path) + ": " + l);
            Corte c = new Corte();
            c.Nombre = Limpio(p[0]); c.Fila = l;
            double[] v = new double[9];
            for (int k = 0; k < 9; k++) v[k] = double.Parse(p[k + 1].Trim(), Inv);
            c.Ax = v[0]; c.Ay = v[1]; c.Bx = v[2]; c.By = v[3]; c.Dx = v[4]; c.Dy = v[5]; c.Fondo = v[6]; c.Zmin = v[7]; c.Zmax = v[8];
            double n = System.Math.Sqrt(c.Dx * c.Dx + c.Dy * c.Dy);
            if (n < 1e-9) throw new System.Exception("Direccion nula en el corte " + c.Nombre);
            c.Dx /= n; c.Dy /= n;
            if (c.Zmax < c.Zmin) { double t = c.Zmax; c.Zmax = c.Zmin; c.Zmin = t; }
            if (c.Largo < 0.05) throw new System.Exception("El corte " + c.Nombre + " es demasiado corto (" + c.Largo + " m)");
            r.Add(c);
        }
        return r;
    }

    static string F(double v) { return v.ToString("0.######", Inv); }

    // Caja alineada a los ejes de la nube que contiene el corte hacia los dos lados (t de -atras a +adelante)
    public static string CajaMundo(Corte c, double atras, double adelante, double zmin, double zmax, double margen)
    {
        double x0 = double.MaxValue, y0 = double.MaxValue, x1 = double.MinValue, y1 = double.MinValue;
        foreach (double t in new double[] { -atras, adelante })
            foreach (double[] q in new double[][] { new double[] { c.Ax, c.Ay }, new double[] { c.Bx, c.By } })
            {
                double x = q[0] + c.Dx * t, y = q[1] + c.Dy * t;
                x0 = System.Math.Min(x0, x); x1 = System.Math.Max(x1, x); y0 = System.Math.Min(y0, y); y1 = System.Math.Max(y1, y);
            }
        return F(x0 - margen) + ":" + F(y0 - margen) + ":" + F(zmin) + ":" + F(x1 + margen) + ":" + F(y1 + margen) + ":" + F(zmax);
    }

    // Giro para CloudCompare: X' = profundidad (hacia donde se mira), Y' = derecha de la imagen, Z' = Z
    static string G(double v) { return v.ToString("0.############", Inv); }
    public static string Giro(Corte c, int lado)
    {
        double dx = c.Dx * lado, dy = c.Dy * lado;
        return G(dx) + " " + G(dy) + " 0 0\r\n" + G(dy) + " " + G(-dx) + " 0 0\r\n0 0 1 0\r\n0 0 0 1\r\n";
    }

    // Caja en ejes girados para un lado (lado = +1 mira como la seccion, -1 al reves)
    public static string CajaGirada(Corte c, int lado, double prof, double zmin, double zmax)
    {
        double dx = c.Dx * lado, dy = c.Dy * lado, rx = dy, ry = -dx;
        double p = dx * c.Ax + dy * c.Ay;
        double ua = rx * c.Ax + ry * c.Ay, ub = rx * c.Bx + ry * c.By;
        return F(p - 0.0005) + ":" + F(System.Math.Min(ua, ub)) + ":" + F(zmin) + ":" + F(p + prof) + ":" + F(System.Math.Max(ua, ub)) + ":" + F(zmax);
    }

    // ------------------------------------------------------------------ PLY
    class Prop { public string Name, Type; public int Size; }
    static int TSize(string t)
    {
        switch (t)
        {
            case "char": case "uchar": case "int8": case "uint8": return 1;
            case "short": case "ushort": case "int16": case "uint16": return 2;
            case "int": case "uint": case "float": case "int32": case "uint32": case "float32": return 4;
            case "double": case "float64": return 8;
        }
        throw new System.Exception("Tipo PLY no soportado: " + t);
    }
    static double Val(byte[] b, int o, string t)
    {
        switch (t)
        {
            case "char": case "int8": return (sbyte)b[o];
            case "uchar": case "uint8": return b[o];
            case "short": case "int16": return System.BitConverter.ToInt16(b, o);
            case "ushort": case "uint16": return System.BitConverter.ToUInt16(b, o);
            case "int": case "int32": return System.BitConverter.ToInt32(b, o);
            case "uint": case "uint32": return System.BitConverter.ToUInt32(b, o);
            case "float": case "float32": return System.BitConverter.ToSingle(b, o);
            default: return System.BitConverter.ToDouble(b, o);
        }
    }

    // Lee los XYZ de un PLY (binario little endian o ascii). Llama a cada(x,y,z).
    public static long LeerPly(string path, System.Action<double, double, double> cada)
    {
        using (var fs = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.Read, 1 << 20))
        {
            var hdr = new System.Text.StringBuilder(); var line = new System.Text.StringBuilder();
            string fmt = null; long nv = 0; bool inV = false, vDone = false; var props = new System.Collections.Generic.List<Prop>();
            var antes = new System.Collections.Generic.List<long[]>();   // elementos antes de vertex: no se esperan
            while (true)
            {
                int ch = fs.ReadByte(); if (ch < 0) throw new System.Exception("PLY sin cabecera: " + path);
                if (ch == '\n')
                {
                    string l = line.ToString().TrimEnd('\r'); line.Length = 0;
                    string[] w = l.Split(new char[] { ' ' }, System.StringSplitOptions.RemoveEmptyEntries);
                    if (w.Length == 0) continue;
                    if (w[0] == "format") fmt = w[1];
                    else if (w[0] == "element") { if (w[1] == "vertex") { inV = true; nv = long.Parse(w[2]); } else { if (inV) vDone = true; inV = false; } }
                    else if (w[0] == "property" && inV && !vDone)
                    {
                        if (w[1] == "list") throw new System.Exception("PLY con listas en vertex: no previsto");
                        props.Add(new Prop { Type = w[1], Name = w[2], Size = TSize(w[1]) });
                    }
                    else if (w[0] == "end_header") break;
                }
                else line.Append((char)ch);
            }
            int ix = props.FindIndex(q => q.Name == "x"), iy = props.FindIndex(q => q.Name == "y"), iz = props.FindIndex(q => q.Name == "z");
            if (ix < 0 || iy < 0 || iz < 0) throw new System.Exception("PLY sin x/y/z: " + path);
            if (fmt == "ascii")
            {
                var sr = new System.IO.StreamReader(fs);
                for (long k = 0; k < nv; k++)
                {
                    string[] w = sr.ReadLine().Split(new char[] { ' ' }, System.StringSplitOptions.RemoveEmptyEntries);
                    cada(double.Parse(w[ix], Inv), double.Parse(w[iy], Inv), double.Parse(w[iz], Inv));
                }
                return nv;
            }
            if (fmt != "binary_little_endian") throw new System.Exception("PLY " + fmt + " no soportado");
            int stride = 0; int[] off = new int[props.Count];
            for (int k = 0; k < props.Count; k++) { off[k] = stride; stride += props[k].Size; }
            int chunk = 65536; byte[] buf = new byte[stride * chunk];
            long left = nv;
            while (left > 0)
            {
                int n = (int)System.Math.Min(chunk, left), need = n * stride, got = 0;
                while (got < need) { int r = fs.Read(buf, got, need - got); if (r <= 0) throw new System.Exception("PLY cortado: " + path); got += r; }
                for (int k = 0; k < n; k++)
                {
                    int b = k * stride;
                    cada(Val(buf, b + off[ix], props[ix].Type), Val(buf, b + off[iy], props[iy].Type), Val(buf, b + off[iz], props[iz].Type));
                }
                left -= n;
            }
            return nv;
        }
    }

    // LINEA ROJA: toma la rebanada (|prof - p| <= medio), la pasa a una grilla de 'celda' en el plano del corte
    // y escribe puntos rojos engrosados (desplazamientos en el plano) un pelo delante del plano por cada lado.
    public static long LineaRoja(string slabPly, string outPly, Corte c, double medio, double celda, double[] desp, double eps)
    {
        double p = c.P, ua = c.Rx * c.Ax + c.Ry * c.Ay, ub = c.Rx * c.Bx + c.Ry * c.By;
        double u0 = System.Math.Min(ua, ub), u1 = System.Math.Max(ua, ub);
        var celdas = new System.Collections.Generic.Dictionary<long, bool>();
        LeerPly(slabPly, (x, y, z) =>
        {
            double d = c.Dx * x + c.Dy * y; if (System.Math.Abs(d - p) > medio) return;
            double u = c.Rx * x + c.Ry * y; if (u < u0 || u > u1 || z < c.Zmin || z > c.Zmax) return;
            long iu = (long)System.Math.Floor((u - u0) / celda), iz = (long)System.Math.Floor((z - c.Zmin) / celda);
            celdas[iu * 4000000L + iz] = true;
        });
        long total = (long)celdas.Count * desp.Length * desp.Length * 2;
        using (var fs = new System.IO.FileStream(outPly, System.IO.FileMode.Create))
        {
            string h = "ply\nformat binary_little_endian 1.0\nelement vertex " + total + "\nproperty double x\nproperty double y\nproperty double z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n";
            byte[] hb = System.Text.Encoding.ASCII.GetBytes(h); fs.Write(hb, 0, hb.Length);
            var bw = new System.IO.BinaryWriter(fs);
            foreach (long key in celdas.Keys)
            {
                long iu = key / 4000000L, iz = key % 4000000L;
                double u = u0 + (iu + 0.5) * celda, z = c.Zmin + (iz + 0.5) * celda;
                foreach (double e in new double[] { -eps, eps })
                    foreach (double du in desp)
                        foreach (double dz in desp)
                        {
                            double uu = u + du, dd = p + e;
                            // punto = D*dd + R*uu  (D y R son ortonormales en planta)
                            bw.Write(c.Dx * dd + c.Rx * uu); bw.Write(c.Dy * dd + c.Ry * uu); bw.Write(z + dz);
                            bw.Write((byte)255); bw.Write((byte)0); bw.Write((byte)0);
                        }
            }
            bw.Flush();
        }
        return total;
    }

    // ------------------------------------------------------------------ DXF exportado de Revit
    class Seg { public string Capa; public double X1, Y1, X2, Y2; public bool Usado; }
    class Txt { public string Capa, S; public double X, Y; }
    static string SinFormato(string s)
    {
        s = System.Text.RegularExpressions.Regex.Replace(s, @"\\[A-Za-z][^;\\{}]*;", "");
        s = s.Replace("{", "").Replace("}", "").Replace("\\P", " ");
        return s.Trim();
    }
    static double DistSeg(Seg g, double x, double y)
    {
        double dx = g.X2 - g.X1, dy = g.Y2 - g.Y1, L2 = dx * dx + dy * dy;
        double t = L2 > 0 ? ((x - g.X1) * dx + (y - g.Y1) * dy) / L2 : 0; t = System.Math.Max(0, System.Math.Min(1, t));
        double px = g.X1 + t * dx - x, py = g.Y1 + t * dy - y; return System.Math.Sqrt(px * px + py * py);
    }
    // Lineas de detalle GRUESAS (capa ...WIDE...) = linea roja del corte.
    // Linea FINA (capa ...THIN...) paralela y al lado = hasta donde llega el fondo (y hacia donde mira el lado A).
    // Texto cerca de la linea gruesa = nombre del corte. Si no hay lineas gruesas, cada linea es un corte.
    public static System.Collections.Generic.List<Corte> LeerDxf(string path, double zmin, double zmax, double fondoDef, System.Collections.Generic.List<string> avisos)
    {
        string[] L = System.IO.File.ReadAllLines(path);
        double esc = 0.001; // INSUNITS: 1 pulg, 2 pie, 4 mm, 5 cm, 6 m
        var segs = new System.Collections.Generic.List<Seg>(); var txts = new System.Collections.Generic.List<Txt>();
        bool enEnt = false;
        for (int i = 0; i + 1 < L.Length; i += 2)
        {
            string c = L[i].Trim(), v = L[i + 1].Trim();
            if (c == "9" && v == "$INSUNITS")
            {
                int u = int.Parse(L[i + 3].Trim());
                esc = u == 1 ? 0.0254 : u == 2 ? 0.3048 : u == 5 ? 0.01 : u == 6 ? 1.0 : 0.001;
            }
            if (c == "2" && v == "ENTITIES") enEnt = true;
            if (c == "0" && v == "ENDSEC") enEnt = false;
            if (!enEnt || c != "0") continue;
            if (v == "LINE" || v == "LWPOLYLINE" || v == "MTEXT" || v == "TEXT")
            {
                string capa = ""; string txt = ""; var xs = new System.Collections.Generic.List<double>(); var ys = new System.Collections.Generic.List<double>();
                double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
                int j = i + 2;
                for (; j + 1 < L.Length; j += 2)
                {
                    string cc = L[j].Trim(), vv = L[j + 1];
                    if (cc == "0") break;
                    if (cc == "8") capa = vv.Trim();
                    else if (cc == "10") { x1 = double.Parse(vv.Trim(), Inv); xs.Add(x1); }
                    else if (cc == "20") { y1 = double.Parse(vv.Trim(), Inv); ys.Add(y1); }
                    else if (cc == "11") x2 = double.Parse(vv.Trim(), Inv);
                    else if (cc == "21") y2 = double.Parse(vv.Trim(), Inv);
                    else if (cc == "1" || cc == "3") txt += vv;
                }
                if (v == "LINE") segs.Add(new Seg { Capa = capa, X1 = x1 * esc, Y1 = y1 * esc, X2 = x2 * esc, Y2 = y2 * esc });
                else if (v == "LWPOLYLINE") { for (int k = 0; k + 1 < xs.Count && k + 1 < ys.Count; k++) segs.Add(new Seg { Capa = capa, X1 = xs[k] * esc, Y1 = ys[k] * esc, X2 = xs[k + 1] * esc, Y2 = ys[k + 1] * esc }); }
                else if (xs.Count > 0 && ys.Count > 0) txts.Add(new Txt { Capa = capa, S = SinFormato(txt), X = xs[0] * esc, Y = ys[0] * esc });
                i = j - 2;
            }
        }
        var gruesas = segs.FindAll(g => g.Capa.ToUpperInvariant().Contains("WIDE"));
        var finas = segs.FindAll(g => !g.Capa.ToUpperInvariant().Contains("WIDE"));
        bool soloUnas = gruesas.Count == 0;
        if (soloUnas) { gruesas = finas; finas = new System.Collections.Generic.List<Seg>(); if (gruesas.Count > 0) avisos.Add("No hay lineas gruesas (Wide Lines): cada linea de detalle se toma como un corte, con fondo de " + fondoDef + " m."); }
        var r = new System.Collections.Generic.List<Corte>(); int n = 0;
        foreach (Seg g in gruesas)
        {
            double len = System.Math.Sqrt((g.X2 - g.X1) * (g.X2 - g.X1) + (g.Y2 - g.Y1) * (g.Y2 - g.Y1));
            if (len < 0.3) continue;
            n++;
            double ux = (g.X2 - g.X1) / len, uy = (g.Y2 - g.Y1) / len;
            double nx = uy, ny = -ux;   // normal
            // linea fina paralela mas cercana que se solape con el corte
            Seg best = null; double bestD = double.MaxValue, bestS = 0;
            foreach (Seg f in finas)
            {
                double fl = System.Math.Sqrt((f.X2 - f.X1) * (f.X2 - f.X1) + (f.Y2 - f.Y1) * (f.Y2 - f.Y1)); if (fl < 0.1) continue;
                double fx = (f.X2 - f.X1) / fl, fy = (f.Y2 - f.Y1) / fl;
                if (System.Math.Abs(fx * ux + fy * uy) < 0.995) continue;           // no paralela (> 6 grados)
                double mx = (f.X1 + f.X2) / 2 - g.X1, my = (f.Y1 + f.Y2) / 2 - g.Y1;
                double along = mx * ux + my * uy; if (along < -0.5 || along > len + 0.5) continue;  // no esta frente al corte
                double d = mx * nx + my * ny;
                if (System.Math.Abs(d) > 0.05 && System.Math.Abs(d) < bestD) { bestD = System.Math.Abs(d); best = f; bestS = System.Math.Sign(d); }
            }
            Corte c = new Corte();
            if (best != null) { best.Usado = true; c.Dx = nx * bestS; c.Dy = ny * bestS; c.Fondo = bestD; }
            else { c.Dx = nx; c.Dy = ny; c.Fondo = fondoDef; }
            c.Ax = g.X1; c.Ay = g.Y1; c.Bx = g.X2; c.By = g.Y2; c.Zmin = zmin; c.Zmax = zmax;
            // nombre: texto mas cercano a la linea (menos de 3 m), sin contar los simbolos de elevacion
            string nom = null; double dn = 3.0;
            foreach (Txt t in txts)
            {
                if (t.S.Length == 0 || t.Capa.ToUpperInvariant() == "G-ANNO-SYMB") continue;
                double d = DistSeg(g, t.X, t.Y); if (d < dn) { dn = d; nom = t.S; }
            }
            c.Nombre = Limpio(nom ?? ("CORTE_" + n));
            c.Fila = c.Nombre + ";" + string.Join(";", new string[] { F(c.Ax), F(c.Ay), F(c.Bx), F(c.By), F(c.Dx), F(c.Dy), F(c.Fondo), F(c.Zmin), F(c.Zmax) });
            if (best == null && !soloUnas) avisos.Add("Corte " + c.Nombre + ": sin linea fina de fondo al lado, se usa fondo de " + fondoDef + " m.");
            r.Add(c);
        }
        // nombres repetidos -> se numeran
        var vistos = new System.Collections.Generic.Dictionary<string, int>(System.StringComparer.OrdinalIgnoreCase);
        foreach (Corte c in r) { int k; if (vistos.TryGetValue(c.Nombre, out k)) { vistos[c.Nombre] = k + 1; c.Nombre = c.Nombre + "_" + (k + 1); c.Fila = c.Nombre + c.Fila.Substring(c.Fila.IndexOf(';')); } else vistos[c.Nombre] = 1; }
        return r;
    }
}
// ---------------------------------------------------------------------------------
// CNBg: trabajos pesados en segundo plano (la ventana no se congela) + captura de mensajes
// ---------------------------------------------------------------------------------
public class CNLog : System.IO.TextWriter
{
    static readonly object L = new object();
    static System.Collections.Generic.List<string> cola = new System.Collections.Generic.List<string>();
    System.Text.StringBuilder linea = new System.Text.StringBuilder();
    public override System.Text.Encoding Encoding { get { return System.Text.Encoding.UTF8; } }
    public override void Write(char c)
    {
        if (c == '\n') { lock (L) cola.Add(linea.ToString().TrimEnd('\r')); linea.Length = 0; }
        else linea.Append(c);
    }
    public static string[] Sacar()
    {
        lock (L) { string[] r = cola.ToArray(); cola.Clear(); return r; }
    }
    public static void Instalar() { System.Console.SetOut(new CNLog()); }
}

public static class CNBg
{
    public static string Error;
    public static long Resultado;
    public static string[] Letras;
    static System.Threading.Thread Lanzar(System.Threading.ThreadStart t)
    {
        Error = null;
        var h = new System.Threading.Thread(() => { try { t(); } catch (System.Exception e) { Error = e.Message; } });
        h.IsBackground = true; h.Start(); return h;
    }
    public static System.Threading.Thread LineaRoja(string slab, string outPly, CNRev.Corte c, double medio)
    {
        return Lanzar(() => { Resultado = CNRev.LineaRoja(slab, outPly, c, medio, 0.002, new double[] { -0.0045, -0.0015, 0.0015, 0.0045 }, 0.0004); });
    }
    public static System.Threading.Thread ToRgba(string src, string dst, double paso, double u0, double v0)
    {
        return Lanzar(() => { CNTif.ToRgba(src, dst, paso, u0, v0); });
    }
    public static string Info;
    public static System.Threading.Thread Componer(string fondoRaw, string rojoRaw, string dstConj, string dstRojo, double po, double dpi)
    {
        return Lanzar(() => { Info = CNSec.Componer(fondoRaw, rojoRaw, dstConj, dstRojo, po, dpi); });
    }
    public static System.Threading.Thread DesdeBmp(string bmp, string dst, CNRev.Corte c, double dx, double dy)
    {
        return Lanzar(() => { Info = CNSec.DesdeBmp(bmp, dst, c, dx, dy); });
    }
    public static System.Threading.Thread Build(string root, string img, string png, double pf, double pb, int maxPx, double baja, double sep, string solo, string dwg)
    {
        return Lanzar(() => { Letras = CNPrep.Build(root, img, png, pf, pb, maxPx, baja, sep, solo, dwg); });
    }
}
// ---------------------------------------------------------------------------------
// CNSec: secciones de Revit -> cortes (par 10 cm + fondo), y armado de las 2 imagenes
// ---------------------------------------------------------------------------------
public static class CNSec
{
    static System.Globalization.CultureInfo Inv = System.Globalization.CultureInfo.InvariantCulture;
    public class Par
    {
        public CNRev.Corte Rojo;     // seccion corta (la linea de corte, en rojo)
        public CNRev.Corte Fondo;    // seccion larga (vista con fondo); null si no hay
        public string Clave, Sugerido, Secciones;
        public bool RojoAuto;        // true si la seccion roja se invento (10 cm) porque solo habia una seccion
    }
    static double Pos(CNRev.Corte c, double dx, double dy) { return dx * c.Ax + dy * c.Ay; }
    static double[] Tramo(CNRev.Corte c, double rx, double ry)
    {
        double a = rx * c.Ax + ry * c.Ay, b = rx * c.Bx + ry * c.By;
        return new double[] { System.Math.Min(a, b), System.Math.Max(a, b) };
    }
    static CNRev.Corte Copia(CNRev.Corte c, double dx, double dy, double fondo)
    {
        CNRev.Corte r = new CNRev.Corte();
        r.Nombre = c.Nombre; r.Fila = c.Fila; r.Ax = c.Ax; r.Ay = c.Ay; r.Bx = c.Bx; r.By = c.By;
        r.Dx = dx; r.Dy = dy; r.Fondo = fondo; r.Zmin = c.Zmin; r.Zmax = c.Zmax;
        return r;
    }

    // Junta las secciones que estan sobre la misma linea (misma direccion, plano a menos de 'tolPlano' m y tramos que se tocan)
    public static System.Collections.Generic.List<Par> Agrupar(System.Collections.Generic.List<CNRev.Corte> secs, double maxRojo, double rojoAuto, double tolPlano)
    {
        var grupos = new System.Collections.Generic.List<System.Collections.Generic.List<CNRev.Corte>>();
        foreach (CNRev.Corte s in secs)
        {
            System.Collections.Generic.List<CNRev.Corte> dest = null;
            foreach (var g in grupos)
            {
                CNRev.Corte b = g[0];
                if (s.Dx * b.Dx + s.Dy * b.Dy < 0.999) continue;
                if (System.Math.Abs(Pos(s, b.Dx, b.Dy) - Pos(b, b.Dx, b.Dy)) > tolPlano) continue;
                double[] t1 = Tramo(s, b.Rx, b.Ry), t2 = Tramo(b, b.Rx, b.Ry);
                if (t1[0] > t2[1] + 0.5 || t2[0] > t1[1] + 0.5) continue;
                dest = g; break;
            }
            if (dest == null) { dest = new System.Collections.Generic.List<CNRev.Corte>(); grupos.Add(dest); }
            dest.Add(s);
        }
        var r = new System.Collections.Generic.List<Par>();
        foreach (var g in grupos)
        {
            g.Sort((x, y) => x.Fondo.CompareTo(y.Fondo));
            CNRev.Corte corta = g[0], larga = g[g.Count - 1];
            Par p = new Par();
            var nombres = new System.Collections.Generic.List<string>();
            foreach (CNRev.Corte c in g) nombres.Add(c.Nombre);
            p.Secciones = string.Join(" + ", nombres.ToArray());
            double zmin = double.MaxValue, zmax = double.MinValue;
            foreach (CNRev.Corte c in g) { zmin = System.Math.Min(zmin, c.Zmin); zmax = System.Math.Max(zmax, c.Zmax); }
            if (g.Count >= 2 && larga.Fondo > corta.Fondo + 0.05)
            {
                p.Fondo = Copia(larga, larga.Dx, larga.Dy, larga.Fondo);
                p.Rojo = Copia(corta, larga.Dx, larga.Dy, corta.Fondo);       // misma direccion que el fondo: imagenes alineadas
            }
            else if (larga.Fondo <= maxRojo)
            {
                p.Rojo = Copia(corta, corta.Dx, corta.Dy, corta.Fondo);       // solo seccion corta
            }
            else
            {
                p.Fondo = Copia(larga, larga.Dx, larga.Dy, larga.Fondo);       // solo seccion larga: la linea roja se inventa
                p.Rojo = Copia(larga, larga.Dx, larga.Dy, rojoAuto); p.RojoAuto = true;
            }
            p.Rojo.Zmin = zmin; p.Rojo.Zmax = zmax;
            if (p.Fondo != null) { p.Fondo.Zmin = zmin; p.Fondo.Zmax = zmax; }
            CNRev.Corte k = p.Fondo ?? p.Rojo;
            double ang = System.Math.Atan2(k.Dy, k.Dx) * 180 / System.Math.PI;
            double[] tr = Tramo(k, k.Rx, k.Ry);
            p.Clave = string.Format(Inv, "{0:0.0}|{1:0}|{2:0.0}|{3:0.0}", Pos(k, k.Dx, k.Dy), ang, tr[0], tr[1]);
            p.Sugerido = CNRev.Limpio(g[0].Nombre);
            r.Add(p);
        }
        return r;
    }

    // ------------------------------------------------------------- imagenes
    class Src
    {
        public CNTif.Info I; public System.IO.FileStream F; public byte[] Row; int rowY = -1;
        public byte[] Get(int y)
        {
            if (y < 0 || y >= I.H) return null;
            if (y != rowY)
            {
                int rps = System.Math.Min(I.Rps, I.H);
                F.Position = I.Off[y / rps] + (long)(y % rps) * I.W * I.Spp;
                CNTif.Fill(F, Row); rowY = y;
            }
            return Row;
        }
    }
    static Src Abrir(string p)
    {
        if (p == null || !System.IO.File.Exists(p)) return null;
        Src s = new Src(); s.I = CNTif.Read(p);
        if (s.I.Comp != 1) throw new System.Exception("TIFF comprimido no previsto: " + p);
        if (s.I.Sx <= 0) throw new System.Exception("TIFF sin tamano de pixel: " + p);
        s.F = System.IO.File.OpenRead(p); s.Row = new byte[s.I.W * s.I.Spp]; return s;
    }

    class Escritor
    {
        System.IO.FileStream fo; System.IO.BinaryWriter bw; System.IO.MemoryStream ms = new System.IO.MemoryStream();
        System.Collections.Generic.List<long> offs = new System.Collections.Generic.List<long>(), cnts = new System.Collections.Generic.List<long>();
        public long Datos;
        public Escritor(string p) { fo = new System.IO.FileStream(p, System.IO.FileMode.Create, System.IO.FileAccess.Write); bw = new System.IO.BinaryWriter(fo); bw.Write((ushort)0x4949); bw.Write((ushort)42); bw.Write((uint)0); }
        public void Fila(byte[] rgba)
        {
            ms.SetLength(0); CNTif.PackBits(rgba, rgba.Length, ms);
            offs.Add(fo.Position); cnts.Add(ms.Length); fo.Write(ms.GetBuffer(), 0, (int)ms.Length);
        }
        public void Cerrar(int W, int H, double step, double u0, double v0, double dpi)
        {
            long pRes = fo.Position; bw.Write((uint)System.Math.Round(dpi * 100)); bw.Write((uint)100);
            long pBits = fo.Position; for (int k = 0; k < 4; k++) bw.Write((ushort)8);
            long pOff = fo.Position; foreach (long v in offs) bw.Write((uint)v);
            long pCnt = fo.Position; foreach (long v in cnts) bw.Write((uint)v);
            long pScale = fo.Position; bw.Write(step); bw.Write(step); bw.Write(0.0);
            long pTie = fo.Position; bw.Write(0.0); bw.Write(0.0); bw.Write(0.0); bw.Write(u0); bw.Write(v0); bw.Write(0.0);
            long pGeo = fo.Position; ushort[] gk = { 1, 1, 0, 2, 1024, 0, 1, 1, 1025, 0, 1, 1 }; foreach (ushort v in gk) bw.Write(v);
            if ((fo.Position & 1) == 1) bw.Write((byte)0);
            long pIfd = fo.Position;
            var tags = new System.Collections.Generic.List<uint[]>();
            tags.Add(new uint[] { 256, 4, 1, (uint)W }); tags.Add(new uint[] { 257, 4, 1, (uint)H });
            tags.Add(new uint[] { 258, 3, 4, (uint)pBits }); tags.Add(new uint[] { 259, 3, 1, 32773 });
            tags.Add(new uint[] { 262, 3, 1, 2 }); tags.Add(new uint[] { 273, 4, (uint)H, (uint)pOff });
            tags.Add(new uint[] { 277, 3, 1, 4 }); tags.Add(new uint[] { 278, 4, 1, 1 });
            tags.Add(new uint[] { 279, 4, (uint)H, (uint)pCnt }); tags.Add(new uint[] { 282, 5, 1, (uint)pRes }); tags.Add(new uint[] { 283, 5, 1, (uint)pRes });
            tags.Add(new uint[] { 284, 3, 1, 1 }); tags.Add(new uint[] { 296, 3, 1, 2 });
            tags.Add(new uint[] { 338, 3, 1, 2 }); tags.Add(new uint[] { 33550, 12, 3, (uint)pScale });
            tags.Add(new uint[] { 33922, 12, 6, (uint)pTie }); tags.Add(new uint[] { 34735, 3, 12, (uint)pGeo });
            bw.Write((ushort)tags.Count);
            foreach (uint[] t in tags)
            {
                bw.Write((ushort)t[0]); bw.Write((ushort)t[1]); bw.Write(t[2]);
                bool inl = (t[1] == 3 && t[2] <= 2 && t[0] != 258 && t[0] != 34735) || (t[1] == 4 && t[2] == 1);
                if (inl && t[1] == 3) { bw.Write((ushort)t[3]); bw.Write((ushort)0); } else bw.Write(t[3]);
            }
            bw.Write((uint)0);
            fo.Position = 4; bw.Write((uint)pIfd); bw.Flush(); fo.Close();
        }
    }

    // Arma las 2 imagenes del corte a 'po' m/pixel, en el mismo marco georreferenciado:
    //   conjunto = vista con fondo + encima la seccion corta pintada de rojo
    //   rojo     = solo la seccion corta en rojo (fondo transparente)
    // fondoRaw puede ser null (solo seccion corta). Devuelve "W x H".
    public static string Componer(string fondoRaw, string rojoRaw, string dstConj, string dstRojo, double po, double dpi)
    {
        Src f = Abrir(fondoRaw), r = Abrir(rojoRaw);
        if (r == null) throw new System.Exception("No hay imagen de la seccion roja");
        try
        {
            double u0 = r.I.U0, u1 = r.I.U0 + r.I.W * r.I.Sx, vt = r.I.V0, vb = r.I.V0 - r.I.H * r.I.Sx;
            if (f != null)
            {
                u0 = System.Math.Min(u0, f.I.U0); u1 = System.Math.Max(u1, f.I.U0 + f.I.W * f.I.Sx);
                vt = System.Math.Max(vt, f.I.V0); vb = System.Math.Min(vb, f.I.V0 - f.I.H * f.I.Sx);
            }
            int W = (int)System.Math.Ceiling((u1 - u0) / po), H = (int)System.Math.Ceiling((vt - vb) / po);
            Escritor ec = dstConj != null && f != null ? new Escritor(dstConj) : null;
            Escritor er = new Escritor(dstRojo);
            byte[] fc = new byte[W * 4], fr = new byte[W * 4]; bool[] mask = new bool[W];
            int ultimaRoja = -1;
            for (int y = 0; y < H; y++)
            {
                double vTop = vt - y * po, vBot = vt - (y + 1) * po, vMid = (vTop + vBot) / 2;
                System.Array.Clear(mask, 0, W);
                int ry0 = (int)System.Math.Floor((r.I.V0 - vTop) / r.I.Sx + 1e-9), ry1 = (int)System.Math.Floor((r.I.V0 - vBot) / r.I.Sx - 1e-9);
                for (int ry = System.Math.Max(0, ry0); ry <= System.Math.Min(r.I.H - 1, ry1); ry++)
                {
                    byte[] b = r.Get(ry); ultimaRoja = ry;
                    for (int rx = 0; rx < r.I.W; rx++)
                    {
                        int a = rx * r.I.Spp;
                        if (b[a] == 0 && b[a + 1] == 0 && b[a + 2] == 0) continue;
                        int ox = (int)System.Math.Floor((r.I.U0 + (rx + 0.5) * r.I.Sx - u0) / po);
                        if (ox >= 0 && ox < W) mask[ox] = true;
                    }
                }
                byte[] bf = null; if (f != null) bf = f.Get((int)System.Math.Floor((f.I.V0 - vMid) / f.I.Sx));
                for (int x = 0; x < W; x++)
                {
                    int o = x * 4;
                    if (mask[x]) { fr[o] = 255; fr[o + 1] = 0; fr[o + 2] = 0; fr[o + 3] = 255; er.Datos++; }
                    else { fr[o] = 0; fr[o + 1] = 0; fr[o + 2] = 0; fr[o + 3] = 0; }
                    if (ec == null) continue;
                    if (mask[x]) { fc[o] = 255; fc[o + 1] = 0; fc[o + 2] = 0; fc[o + 3] = 255; ec.Datos++; continue; }
                    fc[o] = 0; fc[o + 1] = 0; fc[o + 2] = 0; fc[o + 3] = 0;
                    if (bf != null)
                    {
                        int fx = (int)System.Math.Floor((u0 + (x + 0.5) * po - f.I.U0) / f.I.Sx);
                        if (fx >= 0 && fx < f.I.W)
                        {
                            int a = fx * f.I.Spp; byte cr = bf[a], cg = bf[a + 1], cb = bf[a + 2];
                            if (!(cr == 0 && cg == 0 && cb == 0)) { fc[o] = cr; fc[o + 1] = cg; fc[o + 2] = cb; fc[o + 3] = 255; ec.Datos++; }
                        }
                    }
                }
                er.Fila(fr); if (ec != null) ec.Fila(fc);
            }
            er.Cerrar(W, H, po, u0, vt, dpi); if (ec != null) ec.Cerrar(W, H, po, u0, vt, dpi);
            return W + " x " + H;
        }
        finally { if (f != null) f.F.Close(); r.F.Close(); }
    }

    // Caja (en ejes de la nube) que contiene las dos secciones del par, hacia donde miran
    public static string Caja(Par p, double margen)
    {
        double x0 = double.MaxValue, y0 = double.MaxValue, x1 = double.MinValue, y1 = double.MinValue, z0 = double.MaxValue, z1 = double.MinValue;
        foreach (CNRev.Corte c in new CNRev.Corte[] { p.Rojo, p.Fondo })
        {
            if (c == null) continue;
            foreach (double t in new double[] { -0.02, c.Fondo + 0.01 })
                foreach (double[] q in new double[][] { new double[] { c.Ax, c.Ay }, new double[] { c.Bx, c.By } })
                {
                    double x = q[0] + c.Dx * t, y = q[1] + c.Dy * t;
                    x0 = System.Math.Min(x0, x); x1 = System.Math.Max(x1, x); y0 = System.Math.Min(y0, y); y1 = System.Math.Max(y1, y);
                }
            z0 = System.Math.Min(z0, c.Zmin); z1 = System.Math.Max(z1, c.Zmax);
        }
        return string.Format(Inv, "{0:0.######}:{1:0.######}:{2:0.######}:{3:0.######}:{4:0.######}:{5:0.######}", x0 - margen, y0 - margen, z0, x1 + margen, y1 + margen, z1);
    }
    public static string Firma(Par p) { return (p.Rojo != null ? p.Rojo.Fila : "") + "|" + (p.Fondo != null ? p.Fondo.Fila : "") + "|" + (p.Rojo != null ? p.Rojo.Fondo.ToString(Inv) : ""); }


    // pedido al complemento para rasterizar los puntos reales de la nube dentro de la caja de la seccion
    public static string PedidoNube(CNRev.Corte c, double refDx, double refDy, double paso, double relleno, string ruta)
    {
        double[] v = Campos(c.Fila);
        double[] q = { v[0], v[1], v[2], v[3], v[4], v[5], c.Fondo, c.Zmin, c.Zmax, refDx, refDy, paso, relleno };
        System.Text.StringBuilder sb = new System.Text.StringBuilder(ruta);
        foreach (double d in q) sb.Append('|').Append(d.ToString("R", Inv));
        return sb.ToString();
    }
    // ------------------------------------------------------------------ imagenes exportadas por Revit
    static double[] Campos(string fila)
    {
        string[] p = fila.Split(';');
        double[] v = new double[9];
        for (int k = 0; k < 9; k++) v[k] = double.Parse(p[k + 1].Trim(), Inv);
        return v;   // ax ay bx by dx dy fondo zmin zmax  (tal cual los mando Revit)
    }
    public static string IdRevit(CNRev.Corte c) { string[] p = c.Fila.Split(';'); return p.Length > 10 ? p[10].Trim() : ""; }

    // fracciones (0..1) del alto del recorte de Revit que hay que dejar para quedarse entre zlo y zhi
    public static string Fracciones(CNRev.Corte c)
    {
        double[] v = Campos(c.Fila);
        double z0 = System.Math.Min(v[7], v[8]), z1 = System.Math.Max(v[7], v[8]), h = z1 - z0;
        if (h < 1e-6) return "0|1";
        double f0 = System.Math.Max(0, System.Math.Min(1, (c.Zmin - z0) / h)), f1 = System.Math.Max(0, System.Math.Min(1, (c.Zmax - z0) / h));
        if (f1 - f0 < 1e-4) { f0 = 0; f1 = 1; }
        return f0.ToString("0.########", Inv) + "|" + f1.ToString("0.########", Inv);
    }

    // BMP de Revit -> TIFF crudo georreferenciado igual que los de CloudCompare (negro = vacio).
    //   U horizontal en el marco de la vista 'refDx,refDy' (derecha = (dy,-dx)), V = Z.
    //   El borde izquierdo de la imagen de Revit es el punto A de la seccion y el derecho el B.
    public static string DesdeBmp(string bmp, string dst, CNRev.Corte c, double refDx, double refDy)
    {
        double[] v = Campos(c.Fila);
        double rx = refDy, ry = -refDx;
        double uA = rx * v[0] + ry * v[1], uB = rx * v[2] + ry * v[3];
        bool espejo = uA > uB;
        double u0 = System.Math.Min(uA, uB), largo = System.Math.Abs(uB - uA);
        using (System.IO.FileStream fi = System.IO.File.OpenRead(bmp))
        {
            System.IO.BinaryReader br = new System.IO.BinaryReader(fi);
            if (br.ReadUInt16() != 0x4D42) throw new System.Exception("la imagen de Revit no es BMP: " + bmp);
            fi.Position = 10; long off = br.ReadUInt32();
            fi.Position = 18; int W = br.ReadInt32(); int H0 = br.ReadInt32();
            fi.Position = 28; int bpp = br.ReadUInt16();
            fi.Position = 30; int comp = br.ReadInt32();
            if (comp != 0 && comp != 3) throw new System.Exception("BMP comprimido no previsto");
            if (bpp != 24 && bpp != 32) throw new System.Exception("BMP de " + bpp + " bits no previsto");
            bool abajoArriba = H0 > 0; int H = System.Math.Abs(H0);
            int bypp = bpp / 8; long stride = ((long)W * bypp + 3) / 4 * 4;
            double paso = largo / W;
            double alto = c.Zmax - c.Zmin;
            double proporcion = alto > 0 ? (H * paso) / alto : 1;
            byte[] fila = new byte[stride], rgb = new byte[W * 3];
            long datos = 0;
            using (System.IO.FileStream fo = new System.IO.FileStream(dst, System.IO.FileMode.Create, System.IO.FileAccess.Write))
            {
                System.IO.BinaryWriter bw = new System.IO.BinaryWriter(fo);
                bw.Write((ushort)0x4949); bw.Write((ushort)42); bw.Write((uint)0);
                long pDatos = fo.Position;
                for (int y = 0; y < H; y++)
                {
                    long fy = abajoArriba ? (H - 1 - y) : y;
                    fi.Position = off + fy * stride; CNTif.Fill(fi, fila);
                    for (int x = 0; x < W; x++)
                    {
                        int sx = espejo ? (W - 1 - x) : x, a = sx * bypp;
                        byte b = fila[a], g = fila[a + 1], r = fila[a + 2];
                        int o = x * 3;
                        if (r >= 245 && g >= 245 && b >= 245) { rgb[o] = 0; rgb[o + 1] = 0; rgb[o + 2] = 0; continue; }
                        if (r == 0 && g == 0 && b == 0) { r = 1; g = 1; b = 1; }
                        rgb[o] = r; rgb[o + 1] = g; rgb[o + 2] = b; datos++;
                    }
                    fo.Write(rgb, 0, rgb.Length);
                }
                long pBits = fo.Position; for (int k = 0; k < 3; k++) bw.Write((ushort)8);
                long pScale = fo.Position; bw.Write(paso); bw.Write(paso); bw.Write(0.0);
                long pTie = fo.Position; bw.Write(0.0); bw.Write(0.0); bw.Write(0.0); bw.Write(u0); bw.Write(c.Zmax); bw.Write(0.0);
                if ((fo.Position & 1) == 1) bw.Write((byte)0);
                long pIfd = fo.Position;
                var tags = new System.Collections.Generic.List<uint[]>();
                tags.Add(new uint[] { 256, 4, 1, (uint)W }); tags.Add(new uint[] { 257, 4, 1, (uint)H });
                tags.Add(new uint[] { 258, 3, 3, (uint)pBits }); tags.Add(new uint[] { 259, 3, 1, 1 });
                tags.Add(new uint[] { 262, 3, 1, 2 }); tags.Add(new uint[] { 273, 4, 1, (uint)pDatos });
                tags.Add(new uint[] { 277, 3, 1, 3 }); tags.Add(new uint[] { 278, 4, 1, (uint)H });
                tags.Add(new uint[] { 279, 4, 1, (uint)((long)W * 3 * H) }); tags.Add(new uint[] { 284, 3, 1, 1 });
                tags.Add(new uint[] { 33550, 12, 3, (uint)pScale }); tags.Add(new uint[] { 33922, 12, 6, (uint)pTie });
                bw.Write((ushort)tags.Count);
                foreach (uint[] t in tags)
                {
                    bw.Write((ushort)t[0]); bw.Write((ushort)t[1]); bw.Write(t[2]);
                    bool inl = (t[1] == 3 && t[2] <= 2) || (t[1] == 4 && t[2] == 1);
                    if (inl && t[1] == 3) { bw.Write((ushort)t[3]); bw.Write((ushort)0); } else bw.Write(t[3]);
                }
                bw.Write((uint)0);
                fo.Position = 4; bw.Write((uint)pIfd); bw.Flush();
            }
            if (datos == 0) { System.IO.File.Delete(dst); return null; }
            return W + " x " + H + " px, pixel " + (paso * 1000).ToString("0.00", Inv) + " mm, proporcion " + proporcion.ToString("0.000", Inv) + (espejo ? ", volteada" : "");
        }
    }
}
'@
} catch {
  [System.Windows.Forms.MessageBox]::Show("No se pudo preparar el programa:`n`n$($_.Exception.Message)", 'Generador de cortes', 'OK', 'Error') | Out-Null
  return
}
$ErrorActionPreference = 'Stop'
[CNLog]::Instalar()
$Root   = $env:CN_ROOT.TrimEnd('\')
$TifDir = Join-Path $Root 'TIFF'
$DwgDir = Join-Path $Root 'CORTES DWG'
$Tmp    = Join-Path $Root '_temp'
$Png    = Join-Path $Tmp 'png'
foreach ($d in $Tmp) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$RevitTxt = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CortesNube\secciones_revit.txt'
$NombresTxt = Join-Path $Tmp 'nombres_cortes.txt'
$inv = [Globalization.CultureInfo]::InvariantCulture
function F([double]$v) { $v.ToString('0.######', $inv) }
function Q([string]$p) { "`"$p`"" }
if (-not $NUBE) {
  $cn = if ([IO.Path]::IsPathRooted($CARPETA_NUBE)) { $CARPETA_NUBE } else { Join-Path $Root $CARPETA_NUBE }
  $b = Get-ChildItem -LiteralPath $cn -Filter '*.bin' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'B4_SECCIONES*' } | Sort-Object Length -Descending | Select-Object -First 1
  if ($b) { $NUBE = $b.FullName }
}
$NubeTxt = Join-Path $Tmp 'nube_elegida.txt'
if ((Test-Path -LiteralPath $NubeTxt) -and (Test-Path -LiteralPath ((Get-Content -LiteralPath $NubeTxt -Raw).Trim()))) { $NUBE = (Get-Content -LiteralPath $NubeTxt -Raw).Trim() }
$PedidoVinc = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CortesNube\vincular_nube.txt'
$AUTOCAD = (Get-ChildItem 'C:\Program Files\Autodesk\AutoCAD*\acad.exe' -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1).FullName

# ======================= COMPLEMENTO DE REVIT (se compila e instala solo) =======================
$VERSION_MOTOR = 'f598ce1998'
$FUENTE_MOTOR = @'
// CortesNubeMotor: lee los puntos de la nube vinculada dentro de la caja de cada seccion y escribe TIFF crudos.
// Lo carga CortesNube.dll desde bytes (se puede actualizar con Revit abierto).
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Collections.Generic;
using Autodesk.Revit.DB;
using Autodesk.Revit.DB.PointClouds;

namespace CortesNubeMotor
{
    public static class Motor
    {
        static string carpetaLog;
        static void Log(string m) { try { File.AppendAllText(Path.Combine(carpetaLog, "complemento_log.txt"), DateTime.Now.ToString("s") + "  " + m + "\r\n"); } catch (Exception) { } }

        // ---------------------------------------------------------------- nube -> TIFF crudo (sin CloudCompare)
        // Lee los puntos REALES de la nube vinculada (PointCloudInstance.GetPoints) dentro de la caja de cada
        // seccion y los rasteriza: punto mas cercano a quien mira (como CloudCompare PROJ MIN) y relleno de huecos.
        // linea: ruta|ax|ay|bx|by|dx|dy|prof|zlo|zhi|refdx|refdy|paso|relleno   (todo en metros de la nube "G")
        public static void Nubes(Document doc, string[] lineas, string Carpeta)
        {
            carpetaLog = Carpeta;
            Log("motor v6");
            StringBuilder res = new StringBuilder();
            List<PointCloudInstance> pcs = new List<PointCloudInstance>();
            foreach (Element el in new FilteredElementCollector(doc).OfClass(typeof(PointCloudInstance))) { PointCloudInstance q = el as PointCloudInstance; if (q != null) pcs.Add(q); }
            foreach (string raw in lineas)
            {
                string l = raw.Trim(); if (l.Length == 0) continue;
                string[] p = l.Split('|');
                try
                {
                    if (pcs.Count == 0) throw new Exception("el proyecto abierto no tiene una nube de puntos vinculada");
                    if (p.Length < 14) throw new Exception("pedido mal formado");
                    double[] v = new double[13];
                    for (int i = 0; i < 13; i++) v[i] = double.Parse(p[i + 1], CultureInfo.InvariantCulture);
                    string info = Rasterizar(pcs, p[0], v);
                    res.Append(p[0]).Append("|OK|").Append(info).Append("\r\n");
                }
                catch (Exception ex) { Log(ex.ToString()); res.Append(p[0]).Append("|ERROR|").Append(ex.Message.Replace("\r", " ").Replace("\n", " ")).Append("\r\n"); }
            }
            string listo = Path.Combine(Carpeta, "nube_listo.txt");
            File.WriteAllText(listo + ".tmp", res.ToString(), Encoding.UTF8);
            if (File.Exists(listo)) File.Delete(listo);
            File.Move(listo + ".tmp", listo);
        }

        class Caja { public double ax, ay, tx, ty, dx, dy, len, prof, zlo, zhi, rx, ry; }

        // Una nube vinculada. El espacio "G" (metros del generador) se define con la PRIMERA nube: G = k1 * inv1(M).
        // modoF: 0 filtro en coords de la nube, 1 igual con normales al reves, 2 filtro en coords del modelo.
        // modoP: 0 los puntos vienen en coords de la nube (M = T(p)), 1 vienen en coords del modelo (M = p).
        class Nube { public PointCloudInstance pc; public Transform T; public int modoF = -1, modoP = 0; public long total; }
        static Transform G1inv; static double G1k;
        static double[] AG(XYZ m, int color) { XYZ g = G1inv.OfPoint(m); return new double[] { g.X * G1k, g.Y * G1k, g.Z * G1k, color }; }
        static XYZ DeG(double x, double y, double z) { return G1inv.Inverse.OfPoint(new XYZ(x / G1k, y / G1k, z / G1k)); }   // G -> modelo

        static List<Plane> Planos(Nube n, Caja c, double t0, double t1, double u0, double u1)
        {
            List<double[]> defs = new List<double[]>();     // origen (G) y normal hacia ADENTRO (G)
            defs.Add(new double[] { c.ax + c.tx * t0, c.ay + c.ty * t0, 0, c.tx, c.ty, 0 });
            defs.Add(new double[] { c.ax + c.tx * t1, c.ay + c.ty * t1, 0, -c.tx, -c.ty, 0 });
            defs.Add(new double[] { c.ax, c.ay, 0, c.dx, c.dy, 0 });
            defs.Add(new double[] { c.ax + c.dx * c.prof, c.ay + c.dy * c.prof, 0, -c.dx, -c.dy, 0 });
            defs.Add(new double[] { c.ax, c.ay, c.zlo, 0, 0, 1 });
            defs.Add(new double[] { c.ax, c.ay, c.zhi, 0, 0, -1 });
            defs.Add(new double[] { c.rx * u0, c.ry * u0, 0, c.rx, c.ry, 0 });
            defs.Add(new double[] { c.rx * u1, c.ry * u1, 0, -c.rx, -c.ry, 0 });
            Transform ninv = n.T.Inverse;
            List<Plane> pl = new List<Plane>();
            foreach (double[] d in defs)
            {
                XYZ o = DeG(d[0], d[1], d[2]);                                        // modelo
                XYZ q = DeG(d[0] + d[3], d[1] + d[4], d[2] + d[5]);
                XYZ nv = (q - o).Normalize();
                if (n.modoF != 2) { o = ninv.OfPoint(o); nv = ninv.OfVector(nv).Normalize(); }   // coords de la nube
                if (n.modoF == 1) nv = nv.Negate();
                pl.Add(Plane.CreateByNormalAndOrigin(nv, o));
            }
            return pl;
        }

        static double[] Punto(Nube n, CloudPoint q)
        {
            XYZ p = new XYZ(q.X, q.Y, q.Z);
            return AG(n.modoP == 0 ? n.T.OfPoint(p) : p, q.Color);
        }

        static void Pedir(Nube n, Caja c, double t0, double t1, double u0, double u1, double paso, List<double[]> r, int prof)
        {
            const int TOPE = 900000;
            PointCloudFilter f = PointCloudFilterFactory.CreateMultiPlaneFilter(Planos(n, c, t0, t1, u0, u1));
            PointCollection pts = n.pc.GetPoints(f, Math.Max(paso * 0.7 / 0.3048, 1e-5), TOPE);
            if (pts.Count >= TOPE * 0.98 && prof < 12 && (t1 - t0) > 0.02)
            {
                double tm = (t0 + t1) / 2;
                Pedir(n, c, t0, tm, u0, u1, paso, r, prof + 1);
                Pedir(n, c, tm, t1, u0, u1, paso, r, prof + 1);
                return;
            }
            foreach (CloudPoint q in pts) r.Add(Punto(n, q));
        }

        static bool Dentro(Caja c, double[] g, double holgura)
        {
            double px = g[0] - c.ax, py = g[1] - c.ay;
            double t = px * c.tx + py * c.ty, d = px * c.dx + py * c.dy;
            return t > -holgura && t < c.len + holgura && d > -holgura && d < c.prof + holgura && g[2] > c.zlo - holgura && g[2] < c.zhi + holgura;
        }

        static string Rasterizar(List<PointCloudInstance> pcs, string ruta, double[] v)
        {
            G1inv = pcs[0].GetTransform().Inverse;
            G1k = G1inv.OfVector(XYZ.BasisX).GetLength() > 0.9 ? 0.3048 : 1.0;
            Caja c = new Caja();
            c.ax = v[0]; c.ay = v[1];
            double bx = v[2], by = v[3];
            c.len = Math.Sqrt((bx - c.ax) * (bx - c.ax) + (by - c.ay) * (by - c.ay));
            if (c.len < 1e-6) throw new Exception("seccion sin largo");
            c.tx = (bx - c.ax) / c.len; c.ty = (by - c.ay) / c.len;
            double dl = Math.Sqrt(v[4] * v[4] + v[5] * v[5]); c.dx = v[4] / dl; c.dy = v[5] / dl;
            c.prof = v[6]; c.zlo = v[7]; c.zhi = v[8];
            double rl = Math.Sqrt(v[9] * v[9] + v[10] * v[10]);
            c.rx = v[10] / rl; c.ry = -v[9] / rl;              // derecha del marco de referencia = (dy, -dx)
            double paso = v[11], relleno = v[12];
            double uA = c.rx * c.ax + c.ry * c.ay, uB = c.rx * bx + c.ry * by;
            double U0 = Math.Min(uA, uB), U1 = Math.Max(uA, uB);
            int W = (int)Math.Ceiling((U1 - U0) / paso), H = (int)Math.Ceiling((c.zhi - c.zlo) / paso);
            if ((long)W * H * 3 > 3500000000L) throw new Exception("imagen demasiado grande (" + W + " x " + H + ")");
            int R = Math.Max(1, (int)Math.Round(relleno / paso));

            // cada nube: se prueba con una muestra que combinacion de coordenadas devuelve puntos DENTRO de la caja
            List<Nube> nubes = new List<Nube>();
            foreach (PointCloudInstance pc in pcs)
            {
                Nube n = new Nube(); n.pc = pc; n.T = pc.GetTransform();
                int mejor = 0;
                for (int mf = 0; mf < 3; mf++)
                {
                    try
                    {
                        n.modoF = mf;
                        PointCollection pts = pc.GetPoints(PointCloudFilterFactory.CreateMultiPlaneFilter(Planos(n, c, 0, c.len, U0 - 1, U1 + 1)), 0.05 / 0.3048, 3000);
                        int[] dentro = new int[2]; int tot = 0;
                        foreach (CloudPoint q in pts)
                        {
                            tot++;
                            for (int mp = 0; mp < 2; mp++) { n.modoP = mp; if (Dentro(c, Punto(n, q), 0.05)) dentro[mp]++; }
                        }
                        Log("nube '" + pc.Name + "' filtro " + mf + ": " + tot + " puntos, dentro " + dentro[0] + "/" + dentro[1]);
                        for (int mp = 0; mp < 2; mp++) if (tot > 0 && dentro[mp] >= tot * 0.9 && dentro[mp] > mejor) { mejor = dentro[mp]; n.total = mf * 10 + mp + 1; }
                    }
                    catch (Exception ex) { Log("nube '" + pc.Name + "' filtro " + mf + ": " + ex.Message); }
                }
                if (n.total > 0) { n.modoF = (int)((n.total - 1) / 10); n.modoP = (int)((n.total - 1) % 10); n.total = 0; nubes.Add(n); Log("  usando filtro " + n.modoF + ", puntos " + n.modoP); }
            }
            if (nubes.Count == 0) throw new Exception("ninguna nube vinculada tiene puntos dentro de esta seccion (revisa que la nube se vea en la seccion)");

            using (FileStream fo = new FileStream(ruta, FileMode.Create, FileAccess.ReadWrite))
            {
                BinaryWriter bw = new BinaryWriter(fo);
                bw.Write((ushort)0x4949); bw.Write((ushort)42); bw.Write((uint)0);
                long pDatos = 8, total = (long)W * H * 3;
                fo.SetLength(pDatos + total);
                const int TW = 256;
                long npts = 0, nPix = 0;
                for (int x0 = 0; x0 < W; x0 += TW)
                {
                    int x1 = Math.Min(W, x0 + TW), ex0 = x0 - R, tw = (x1 - x0) + 2 * R;
                    double tu0 = U0 + ex0 * paso, tu1 = U0 + (x1 + R) * paso;
                    int[] col = new int[tw * H]; float[] prof = new float[tw * H];
                    for (int i = 0; i < col.Length; i++) { col[i] = -1; prof[i] = float.MaxValue; }
                    List<double[]> pts = new List<double[]>();
                    foreach (Nube n in nubes) Pedir(n, c, 0, c.len, tu0, tu1, paso, pts, 0);
                    foreach (double[] g in pts)
                    {
                        double u = c.rx * g[0] + c.ry * g[1];
                        int x = (int)Math.Floor((u - U0) / paso) - ex0, y = (int)Math.Floor((c.zhi - g[2]) / paso);
                        if (x < 0 || x >= tw || y < 0 || y >= H) continue;
                        float d = (float)((g[0] - c.ax) * c.dx + (g[1] - c.ay) * c.dy);
                        int i = y * tw + x;
                        if (d < prof[i]) { prof[i] = d; col[i] = ((int)g[3]) & 0xFFFFFF; }
                    }
                    npts += pts.Count; pts = null; prof = null;
                    // relleno: promedio de los vecinos con dato dentro de R pixeles (tabla de sumas por columnas)
                    int[] sr = new int[tw], sg = new int[tw], sb = new int[tw], sn = new int[tw];
                    byte[] fila = new byte[(x1 - x0) * 3];
                    for (int y = -R; y < H; y++)
                    {
                        int ya = y + R;                               // fila que entra
                        if (ya < H) for (int x = 0; x < tw; x++) { int q = col[ya * tw + x]; if (q >= 0) { sr[x] += q & 255; sg[x] += (q >> 8) & 255; sb[x] += (q >> 16) & 255; sn[x]++; } }
                        int ys = y - R - 1;                           // fila que sale
                        if (ys >= 0) for (int x = 0; x < tw; x++) { int q = col[ys * tw + x]; if (q >= 0) { sr[x] -= q & 255; sg[x] -= (q >> 8) & 255; sb[x] -= (q >> 16) & 255; sn[x]--; } }
                        if (y < 0) continue;
                        int ar = 0, ag = 0, ab = 0, an = 0;
                        for (int x = 0; x < 2 * R; x++) { ar += sr[x]; ag += sg[x]; ab += sb[x]; an += sn[x]; }
                        for (int cx = R; cx < tw - R; cx++)
                        {
                            int xe = cx + R; ar += sr[xe]; ag += sg[xe]; ab += sb[xe]; an += sn[xe];
                            if (cx - R - 1 >= 0) { int xs = cx - R - 1; ar -= sr[xs]; ag -= sg[xs]; ab -= sb[xs]; an -= sn[xs]; }
                            int o = (cx - R) * 3, q = col[y * tw + cx];
                            byte r8, g8, b8;
                            if (q >= 0) { r8 = (byte)(q & 255); g8 = (byte)((q >> 8) & 255); b8 = (byte)((q >> 16) & 255); }
                            else if (an >= 3) { r8 = (byte)(ar / an); g8 = (byte)(ag / an); b8 = (byte)(ab / an); }
                            else { fila[o] = 0; fila[o + 1] = 0; fila[o + 2] = 0; continue; }
                            if (r8 == 0 && g8 == 0 && b8 == 0) { r8 = 1; g8 = 1; b8 = 1; }
                            fila[o] = r8; fila[o + 1] = g8; fila[o + 2] = b8; nPix++;
                        }
                        fo.Position = pDatos + ((long)y * W + x0) * 3;
                        fo.Write(fila, 0, fila.Length);
                    }
                    col = null;
                }
                fo.Position = pDatos + total;
                long pBits = fo.Position; for (int i = 0; i < 3; i++) bw.Write((ushort)8);
                long pScale = fo.Position; bw.Write(paso); bw.Write(paso); bw.Write(0.0);
                long pTie = fo.Position; bw.Write(0.0); bw.Write(0.0); bw.Write(0.0); bw.Write(U0); bw.Write(c.zhi); bw.Write(0.0);
                if ((fo.Position & 1) == 1) bw.Write((byte)0);
                long pIfd = fo.Position;
                uint[][] tags = new uint[][] {
                    new uint[] { 256, 4, 1, (uint)W }, new uint[] { 257, 4, 1, (uint)H }, new uint[] { 258, 3, 3, (uint)pBits },
                    new uint[] { 259, 3, 1, 1 }, new uint[] { 262, 3, 1, 2 }, new uint[] { 273, 4, 1, (uint)pDatos },
                    new uint[] { 277, 3, 1, 3 }, new uint[] { 278, 4, 1, (uint)H }, new uint[] { 279, 4, 1, (uint)total },
                    new uint[] { 284, 3, 1, 1 }, new uint[] { 33550, 12, 3, (uint)pScale }, new uint[] { 33922, 12, 6, (uint)pTie } };
                bw.Write((ushort)tags.Length);
                foreach (uint[] t in tags)
                {
                    bw.Write((ushort)t[0]); bw.Write((ushort)t[1]); bw.Write(t[2]);
                    if (t[1] == 3 && t[2] == 1) { bw.Write((ushort)t[3]); bw.Write((ushort)0); } else bw.Write(t[3]);
                }
                bw.Write((uint)0);
                fo.Position = 4; bw.Write((uint)pIfd); bw.Flush();
                return W + " x " + H + " px, " + npts + " puntos de " + nubes.Count + " nube(s), " + nPix + " pixeles con dato";
            }
        }

    }
}
'@
$VERSION_COMPLEMENTO = '398a8e5000'
$FUENTE_COMPLEMENTO = @'
// Complemento de Revit "Cortes nube" (Quinta Heeren)
// Escribe en vivo las SECCIONES del proyecto abierto en  Documentos\CortesNube\secciones_revit.txt
// (coordenadas de la nube vinculada, en metros) para que GENERADOR_DE_CORTES las procese.
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Collections.Generic;
using Autodesk.Revit.Attributes;
using Autodesk.Revit.DB;
using Autodesk.Revit.DB.PointClouds;
using Autodesk.Revit.DB.Events;
using Autodesk.Revit.UI;
using Autodesk.Revit.UI.Events;

namespace CortesNube
{
    public class App : IExternalApplication
    {
        static bool sucio = true;
        static string ultimo = "";

        public Result OnStartup(UIControlledApplication a)
        {
            a.ControlledApplication.DocumentChanged += Cambio;
            a.ControlledApplication.DocumentOpened += Abierto;
            a.ViewActivated += Vista;
            a.Idling += Ocioso;
            try
            {
                Directory.CreateDirectory(Carpeta);
                evento = ExternalEvent.Create(new Pedidos());
                try { ventana = a.MainWindowHandle; } catch (Exception) { }
                reloj = new System.Threading.Timer(Revisar, null, 2000, 1500);
            }
            catch (Exception ex) { Log(ex.ToString()); }
            try
            {
                RibbonPanel p = a.CreateRibbonPanel("Cortes nube");
                PushButtonData b = new PushButtonData("cnEnviar", "Enviar cortes\nal generador", typeof(App).Assembly.Location, "CortesNube.Enviar");
                b.ToolTip = "Las secciones se envian solas al generador de cortes. Este boton lo fuerza y muestra cuantas hay.";
                p.AddItem(b);
            }
            catch (Exception) { }
            return Result.Succeeded;
        }

        public Result OnShutdown(UIControlledApplication a) { return Result.Succeeded; }

        static void Cambio(object s, DocumentChangedEventArgs e) { sucio = true; }
        static void Abierto(object s, DocumentOpenedEventArgs e) { sucio = true; }
        static void Vista(object s, ViewActivatedEventArgs e) { sucio = true; }

        static DateTime ultimaRevision = DateTime.MinValue;
        static ExternalEvent evento;
        static System.Threading.Timer reloj;
        static IntPtr ventana = IntPtr.Zero;
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

        // cada 1.5 s (hilo aparte): si el generador dejo un pedido, despierta a Revit
        static void Revisar(object o)
        {
            try
            {
                if (evento == null) return;
                if (File.Exists(Path.Combine(Carpeta, "vincular_nube.txt")) || File.Exists(Path.Combine(Carpeta, "exportar_imagenes.txt")) || File.Exists(Path.Combine(Carpeta, "exportar_nube.txt")))
                {
                    evento.Raise();
                    if (ventana != IntPtr.Zero) PostMessage(ventana, 0, IntPtr.Zero, IntPtr.Zero);
                }
            }
            catch (Exception) { }
        }

        public static void AtenderPedidos(UIApplication ua)
        {
            if (ua == null || ua.ActiveUIDocument == null) return;
            Document doc = ua.ActiveUIDocument.Document;
            string pedido = Path.Combine(Carpeta, "vincular_nube.txt");
            if (File.Exists(pedido))
            {
                string ruta = "";
                try { ruta = File.ReadAllText(pedido).Trim(); File.Delete(pedido); } catch (Exception) { }
                if (ruta.Length > 0) Vincular(doc, ruta);
            }
            pedido = Path.Combine(Carpeta, "exportar_nube.txt");
            if (File.Exists(pedido))
            {
                string[] lineas = null;
                try { lineas = File.ReadAllLines(pedido); File.Delete(pedido); } catch (Exception) { }
                if (lineas != null) Nubes(doc, lineas);
            }
            pedido = Path.Combine(Carpeta, "exportar_imagenes.txt");
            if (File.Exists(pedido))
            {
                string[] lineas = null;
                try { lineas = File.ReadAllLines(pedido); File.Delete(pedido); } catch (Exception) { }
                if (lineas != null) Imagenes(doc, lineas);
            }
        }

        // Exporta cada seccion pedida como BMP, tal como se ve en Revit, solo con la nube
        // (sin anotaciones, sin marco de recorte, sin otros elementos). Todo se deshace al terminar.
        // linea: id|rutaSinExtension|anchoPixeles|f0|f1|lejano_m   (f0/f1 = fraccion de alto del recorte a dejar)
        static void Imagenes(Document doc, string[] lineas)
        {
            StringBuilder res = new StringBuilder();
            const double PIE = 0.3048;
            foreach (string raw in lineas)
            {
                string l = raw.Trim(); if (l.Length == 0) continue;
                string[] p = l.Split('|');
                string id = p[0];
                try
                {
                    if (p.Length < 6) throw new Exception("pedido mal formado");
                    string ruta = p[1];
                    int ancho = int.Parse(p[2], CultureInfo.InvariantCulture);
                    double f0 = double.Parse(p[3], CultureInfo.InvariantCulture), f1 = double.Parse(p[4], CultureInfo.InvariantCulture);
                    double lejano = double.Parse(p[5], CultureInfo.InvariantCulture);
                    ViewSection v = null;
                    foreach (Element el in new FilteredElementCollector(doc).OfClass(typeof(ViewSection)))
                        if (el.Id.ToString() == id) { v = el as ViewSection; break; }
                    if (v == null) throw new Exception("no encuentro la seccion " + id + " en el proyecto abierto");
                    string dir = Path.GetDirectoryName(ruta);
                    Directory.CreateDirectory(dir);
                    DateTime t0 = DateTime.Now.AddSeconds(-2);
                    using (TransactionGroup tg = new TransactionGroup(doc, "Cortes nube: imagen"))
                    {
                        tg.Start();
                        using (Transaction t = new Transaction(doc, "Preparar vista"))
                        {
                            t.Start();
                            Probar(() => { if (v.ViewTemplateId != ElementId.InvalidElementId) v.ViewTemplateId = ElementId.InvalidElementId; });
                            Probar(() => { v.CropBoxActive = true; });
                            Probar(() => { v.CropBoxVisible = false; });
                            Probar(() => { Parameter pa = v.get_Parameter(BuiltInParameter.VIEWER_ANNOTATION_CROP_ACTIVE); if (pa != null && !pa.IsReadOnly) pa.Set(0); });
                            Probar(() => { v.AreAnnotationCategoriesHidden = true; });
                            ElementId nubes = new ElementId(BuiltInCategory.OST_PointClouds);
                            foreach (Category c in doc.Settings.Categories)
                            {
                                Category cc = c;
                                if (cc.Id == nubes) continue;
                                Probar(() => { if (v.CanCategoryBeHidden(cc.Id)) v.SetCategoryHidden(cc.Id, true); });
                            }
                            Probar(() => { v.SetCategoryHidden(nubes, false); });
                            if (lejano > 0)
                            {
                                Probar(() => { Parameter pc = v.get_Parameter(BuiltInParameter.VIEWER_BOUND_FAR_CLIPPING); if (pc != null && !pc.IsReadOnly) pc.Set(2); });
                                Probar(() => { Parameter pl = v.get_Parameter(BuiltInParameter.VIEWER_BOUND_OFFSET_FAR); if (pl != null && !pl.IsReadOnly) pl.Set(lejano / PIE); });
                            }
                            BoundingBoxXYZ cb = v.CropBox;
                            double h = cb.Max.Y - cb.Min.Y, y0 = cb.Min.Y;
                            cb.Min = new XYZ(cb.Min.X, y0 + f0 * h, cb.Min.Z);
                            cb.Max = new XYZ(cb.Max.X, y0 + f1 * h, cb.Max.Z);
                            v.CropBox = cb;
                            t.Commit();
                        }
                        ImageExportOptions o = new ImageExportOptions();
                        o.ExportRange = ExportRange.SetOfViews;
                        o.SetViewsAndSheets(new List<ElementId> { v.Id });
                        o.FilePath = ruta;
                        o.HLRandWFViewsFileType = ImageFileType.BMP;
                        o.ShadowViewsFileType = ImageFileType.BMP;
                        o.ZoomType = ZoomFitType.FitToPage;
                        o.FitDirection = FitDirectionType.Horizontal;
                        o.PixelSize = ancho;
                        o.ImageResolution = ImageResolution.DPI_600;
                        doc.ExportImage(o);
                        tg.RollBack();
                    }
                    // Revit agrega el nombre de la vista al archivo: buscar el BMP nuevo y renombrarlo
                    string dest = ruta + ".bmp", hallado = null; DateTime mejor = DateTime.MinValue;
                    foreach (string f in Directory.GetFiles(dir, Path.GetFileName(ruta) + "*.bmp"))
                    {
                        DateTime w = File.GetLastWriteTime(f);
                        if (w >= t0 && w > mejor) { mejor = w; hallado = f; }
                    }
                    if (hallado == null) throw new Exception("Revit no creo la imagen");
                    if (!string.Equals(hallado, dest, StringComparison.OrdinalIgnoreCase)) { if (File.Exists(dest)) File.Delete(dest); File.Move(hallado, dest); }
                    res.Append(id).Append("|OK|").Append(dest).Append("\r\n");
                }
                catch (Exception ex) { Log(ex.ToString()); res.Append(id).Append("|ERROR|").Append(ex.Message.Replace("\r", " ").Replace("\n", " ")).Append("\r\n"); }
            }
            string listo = Path.Combine(Carpeta, "exportar_listo.txt");
            File.WriteAllText(listo + ".tmp", res.ToString(), Encoding.UTF8);
            if (File.Exists(listo)) File.Delete(listo);
            File.Move(listo + ".tmp", listo);
        }

        // ---------------------------------------------------------------- motor (se recarga sin reiniciar Revit)
        // La lectura de la nube vive en CortesNubeMotor.dll (junto a este .dll). Se carga desde bytes, asi el
        // generador puede actualizarla con Revit abierto: la siguiente vez se usa la nueva.
        static System.Reflection.MethodInfo motorNubes; static DateTime motorFecha = DateTime.MinValue;
        static void Nubes(Document doc, string[] lineas)
        {
            string dll = Path.Combine(Path.GetDirectoryName(typeof(App).Assembly.Location), "CortesNubeMotor.dll");
            try
            {
                if (!File.Exists(dll)) throw new Exception("falta CortesNubeMotor.dll: vuelve a abrir el generador de cortes");
                DateTime f = File.GetLastWriteTimeUtc(dll);
                if (motorNubes == null || f != motorFecha)
                {
                    System.Reflection.Assembly asm = System.Reflection.Assembly.Load(File.ReadAllBytes(dll));
                    motorNubes = asm.GetType("CortesNubeMotor.Motor").GetMethod("Nubes");
                    motorFecha = f;
                }
                motorNubes.Invoke(null, new object[] { doc, lineas, Carpeta });
            }
            catch (Exception ex)
            {
                Exception e = ex is System.Reflection.TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex;
                Log(e.ToString());
                StringBuilder res = new StringBuilder();
                foreach (string l in lineas) if (l.Trim().Length > 0) res.Append(l.Split('|')[0]).Append("|ERROR|").Append(e.Message.Replace("\r", " ").Replace("\n", " ")).Append("\r\n");
                string listo = Path.Combine(Carpeta, "nube_listo.txt");
                File.WriteAllText(listo + ".tmp", res.ToString(), Encoding.UTF8);
                if (File.Exists(listo)) File.Delete(listo);
                File.Move(listo + ".tmp", listo);
            }
        }

        static void Probar(Action a) { try { a(); } catch (Exception) { } }

        static void Ocioso(object s, IdlingEventArgs e)
        {
            UIApplication ua = s as UIApplication;
            if (ua == null || ua.ActiveUIDocument == null) return;
            // pedidos del generador (vincular nube / exportar imagenes): tambien por si el evento externo no llego
            if ((DateTime.Now - ultimaRevision).TotalSeconds > 1)
            {
                ultimaRevision = DateTime.Now;
                try { AtenderPedidos(ua); } catch (Exception ex) { Log(ex.ToString()); }
            }
            if (!sucio) return;
            sucio = false;
            try { Exportar(ua.ActiveUIDocument.Document, false); }
            catch (Exception ex) { Log(ex.ToString()); }
        }

        public static void Vincular(Document doc, string ruta)
        {
            try
            {
                if (!File.Exists(ruta)) { TaskDialog.Show("Cortes nube", "No existe la nube:\n" + ruta); return; }
                if (doc.IsFamilyDocument) { TaskDialog.Show("Cortes nube", "Abre un PROYECTO de Revit (no una familia) para vincular la nube."); return; }
                string ext = Path.GetExtension(ruta).TrimStart('.').ToLowerInvariant();
                if (ext != "rcp" && ext != "rcs") { TaskDialog.Show("Cortes nube", "La nube debe ser .rcp o .rcs:\n" + ruta); return; }
                using (Transaction t = new Transaction(doc, "Vincular nube (Cortes nube)"))
                {
                    t.Start();
                    PointCloudType tipo = PointCloudType.Create(doc, ext, ruta);
                    PointCloudInstance.Create(doc, tipo.Id, Transform.Identity);
                    t.Commit();
                }
                sucio = true;
                TaskDialog.Show("Cortes nube", "Nube vinculada en el proyecto (origen a origen interno):\n" + ruta + "\n\nAhora haz tus secciones.");
            }
            catch (Exception ex) { Log(ex.ToString()); TaskDialog.Show("Cortes nube", "No se pudo vincular la nube:\n" + ex.Message); }
        }

        public static string Carpeta
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "CortesNube"); }
        }

        static void Log(string s)
        {
            try { Directory.CreateDirectory(Carpeta); File.AppendAllText(Path.Combine(Carpeta, "complemento_log.txt"), DateTime.Now.ToString("s") + "  " + s + "\r\n"); }
            catch (Exception) { }
        }

        static string F(double v) { return v.ToString("0.######", CultureInfo.InvariantCulture); }

        public static int Exportar(Document doc, bool forzar)
        {
            const double PIE = 0.3048;
            Transform inv = Transform.Identity;
            string nube = "SIN NUBE VINCULADA";
            FilteredElementCollector pcs = new FilteredElementCollector(doc).OfClass(typeof(PointCloudInstance));
            foreach (Element el in pcs)
            {
                PointCloudInstance pc = el as PointCloudInstance;
                if (pc == null) continue;
                inv = pc.GetTransform().Inverse;
                nube = pc.Name;
                break;
            }
            // la transformacion de la nube ya pasa de pies (Revit) a metros (nube); sin nube hay que convertir
            double k = inv.OfVector(XYZ.BasisX).GetLength() > 0.9 ? PIE : 1.0;
            StringBuilder sb = new StringBuilder();
            sb.Append("# proyecto: ").Append(doc.Title).Append("\r\n");
            sb.Append("# nube: ").Append(nube).Append("\r\n");
            sb.Append("nombre;ax;ay;bx;by;dx;dy;fondo;zmin;zmax;id\r\n");
            int n = 0;
            FilteredElementCollector vs = new FilteredElementCollector(doc).OfClass(typeof(ViewSection));
            foreach (Element el in vs)
            {
                ViewSection v = el as ViewSection;
                if (v == null || v.IsTemplate || v.ViewType != ViewType.Section) continue;
                BoundingBoxXYZ cb = v.CropBox;
                if (cb == null) continue;
                Transform T = cb.Transform;
                XYZ a = inv.OfPoint(T.OfPoint(new XYZ(cb.Min.X, 0, 0)));
                XYZ b = inv.OfPoint(T.OfPoint(new XYZ(cb.Max.X, 0, 0)));
                XYZ d = inv.OfVector(T.BasisZ.Negate());
                double fondo = Math.Abs(cb.Min.Z) * PIE;
                Parameter pf = v.get_Parameter(BuiltInParameter.VIEWER_BOUND_OFFSET_FAR);
                if (pf != null && pf.HasValue && pf.AsDouble() > 0) fondo = pf.AsDouble() * PIE;
                double z1 = inv.OfPoint(T.OfPoint(new XYZ(0, cb.Min.Y, 0))).Z * k;
                double z2 = inv.OfPoint(T.OfPoint(new XYZ(0, cb.Max.Y, 0))).Z * k;
                string nom = v.Name.Replace(";", ",");
                sb.Append(nom).Append(';').Append(F(a.X * k)).Append(';').Append(F(a.Y * k)).Append(';')
                  .Append(F(b.X * k)).Append(';').Append(F(b.Y * k)).Append(';').Append(F(d.X)).Append(';').Append(F(d.Y)).Append(';')
                  .Append(F(fondo)).Append(';').Append(F(Math.Min(z1, z2))).Append(';').Append(F(Math.Max(z1, z2))).Append(';')
                  .Append(v.Id.ToString()).Append("\r\n");
                n++;
            }
            string txt = sb.ToString();
            if (!forzar && txt == ultimo) return n;
            Directory.CreateDirectory(Carpeta);
            string ruta = Path.Combine(Carpeta, "secciones_revit.txt");
            string tmp = ruta + ".tmp";
            File.WriteAllText(tmp, txt, Encoding.UTF8);
            if (File.Exists(ruta)) File.Delete(ruta);
            File.Move(tmp, ruta);
            ultimo = txt;
            return n;
        }
    }

    public class Pedidos : IExternalEventHandler
    {
        public void Execute(UIApplication app) { try { App.AtenderPedidos(app); } catch (Exception ex) { TaskDialog.Show("Cortes nube", ex.Message); } }
        public string GetName() { return "Cortes nube - pedidos del generador"; }
    }

    [Transaction(TransactionMode.ReadOnly)]
    public class Enviar : IExternalCommand
    {
        public Result Execute(ExternalCommandData data, ref string message, ElementSet elements)
        {
            try
            {
                int n = App.Exportar(data.Application.ActiveUIDocument.Document, true);
                TaskDialog.Show("Cortes nube", n + " seccion(es) enviadas al generador de cortes.\n\n" + Path.Combine(App.Carpeta, "secciones_revit.txt"));
                return Result.Succeeded;
            }
            catch (Exception ex) { message = ex.Message; return Result.Failed; }
        }
    }
}
'@
function VersionesRevit {
  $r = @()
  foreach ($rv in @(Get-ChildItem 'C:\Program Files\Autodesk' -Directory -Filter 'Revit 20*' -ErrorAction SilentlyContinue)) {
    if ($rv.Name -notmatch '^Revit (20\d\d)$') { continue }
    if (-not (Test-Path (Join-Path $rv.FullName 'RevitAPI.dll'))) { continue }
    $r += New-Object PSObject -Property @{ Anio = [int]$Matches[1]; Carpeta = $rv.FullName; Version = (Get-Item (Join-Path $rv.FullName 'RevitAPI.dll')).VersionInfo.FileVersion }
  }
  @($r | Sort-Object Anio)
}
# compila un .cs contra la API de un Revit; devuelve '' si salio bien o el mensaje del compilador
function CompilarRevit($v, [string]$fuente, [string]$salidaDll, [bool]$conUI) {
  $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  if (-not (Test-Path $csc)) { $csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' }
  $api = Join-Path $v.Carpeta 'RevitAPI.dll'; $apiui = Join-Path $v.Carpeta 'RevitAPIUI.dll'
  $src = Join-Path $env:TEMP ('CN_' + [IO.Path]::GetFileNameWithoutExtension($salidaDll) + '.cs'); [IO.File]::WriteAllText($src, $fuente)
  $rv = @("/r:`"$api`""); if ($conUI) { $rv += "/r:`"$apiui`"" }
  $salida = ''
  if ($v.Anio -le 2024) {
    Remove-Item $salidaDll -Force -ErrorAction SilentlyContinue
    $a = @('/nologo', '/target:library', '/optimize+', "/out:`"$salidaDll`"") + $rv + "`"$src`""
    $salida = & $csc @a 2>&1 | Out-String
    if (Test-Path $salidaDll) { return '' }
  } else {
    $cores = @(Get-ChildItem 'C:\Program Files\dotnet\shared\Microsoft.NETCore.App' -Directory -ErrorAction SilentlyContinue | Sort-Object { try { [version]($_.Name -replace '-.*', '') } catch { [version]'0.0' } })
    foreach ($core in $cores) {
      Remove-Item $salidaDll -Force -ErrorAction SilentlyContinue
      $refs = @('System.Private.CoreLib.dll', 'System.Runtime.dll', 'System.Collections.dll', 'System.Runtime.Extensions.dll', 'netstandard.dll', 'mscorlib.dll', 'System.Text.Encoding.Extensions.dll') | ForEach-Object { Join-Path $core.FullName $_ } | Where-Object { Test-Path $_ }
      $a = @('/nologo', '/nostdlib+', '/noconfig', '/target:library', '/optimize+', "/out:`"$salidaDll`"") + ($refs | ForEach-Object { "/r:`"$_`"" }) + $rv + "`"$src`""
      $salida = & $csc @a 2>&1 | Out-String
      if (Test-Path $salidaDll) { return '' }
    }
  }
  if (-not $salida) { $salida = 'no se pudo compilar' }
  return $salida
}

function InstalarComplemento([bool]$forzar) {
  $hechos = @(); $errores = @()
  foreach ($v in (VersionesRevit)) {
    if ($v.Anio -lt $REVIT_MINIMO) { continue }
    $dir = Join-Path $env:APPDATA "Autodesk\Revit\Addins\$($v.Anio)"; $sub = Join-Path $dir 'CortesNube'
    $dll = Join-Path $sub 'CortesNube.dll'; $man = Join-Path $dir 'CortesNube.addin'; $marca = Join-Path $sub 'version.txt'
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    # 1) motor (lectura de la nube): se puede cambiar con Revit abierto, no hace falta reiniciarlo
    $mdll = Join-Path $sub 'CortesNubeMotor.dll'; $mmarca = Join-Path $sub 'motor.txt'; $mfirma = "$VERSION_MOTOR|$($v.Version)"
    if ($forzar -or -not (Test-Path $mdll) -or -not (Test-Path $mmarca) -or ((Get-Content $mmarca -Raw).Trim() -ne $mfirma)) {
      $tmpM = Join-Path $env:TEMP "CortesNubeMotor_$($v.Anio).dll"
      $err = CompilarRevit $v $FUENTE_MOTOR $tmpM $false
      if ($err) { $errores += "Revit $($v.Anio): no se pudo compilar el motor.`n$err" }
      else { try { Copy-Item $tmpM $mdll -Force; (Get-Item $mdll).LastWriteTime = Get-Date; [IO.File]::WriteAllText($mmarca, $mfirma); $errores += "(info) motor actualizado en Revit $($v.Anio) ($VERSION_MOTOR)" } catch { $errores += "Revit $($v.Anio): no se pudo copiar el motor: $($_.Exception.Message)" } }
    }
    # 2) complemento (lo carga Revit al abrir; si cambia hay que reiniciar Revit)
    $firma = "$VERSION_COMPLEMENTO|$($v.Version)"
    if (-not $forzar -and (Test-Path $dll) -and (Test-Path $man) -and (Test-Path $marca) -and ((Get-Content $marca -Raw).Trim() -eq $firma)) { continue }
    $tmpDll = Join-Path $env:TEMP "CortesNube_$($v.Anio).dll"
    $err = CompilarRevit $v $FUENTE_COMPLEMENTO $tmpDll $true
    if ($err) { $errores += "Revit $($v.Anio): no se pudo compilar el complemento.`n$err"; continue }
    try { Copy-Item $tmpDll $dll -Force } catch { $errores += "Revit $($v.Anio): esta abierto. Cierralo y vuelve a abrir este programa para actualizar el complemento."; continue }
    $xml = '<?xml version="1.0" encoding="utf-8"?>' + "`r`n<RevitAddIns>`r`n  <AddIn Type=`"Application`">`r`n    <Name>Cortes nube</Name>`r`n    <Assembly>$dll</Assembly>`r`n    <AddInId>6F1B2C3D-4E5F-4A7B-8C9D-0E1F2A3B4C5D</AddInId>`r`n    <FullClassName>CortesNube.App</FullClassName>`r`n    <VendorId>QHCN</VendorId>`r`n    <VendorDescription>Quinta Heeren - cortes de nube</VendorDescription>`r`n  </AddIn>`r`n</RevitAddIns>`r`n"
    [IO.File]::WriteAllText($man, $xml, (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($marca, $firma)
    $hechos += "Revit $($v.Anio)"
  }
  return @{ Hechos = $hechos; Errores = $errores }
}

# ======================= CHEQUEO DE VERSION (antes de abrir la ventana) =======================
$script:revits = @(VersionesRevit)
$validos = @($script:revits | Where-Object { $_.Anio -ge $REVIT_MINIMO })
if ($validos.Count -eq 0) {
  $hay = if ($script:revits.Count) { 'Se encontro: ' + (($script:revits | ForEach-Object { "Revit $($_.Anio)" }) -join ', ') } else { 'No se encontro ningun Revit instalado.' }
  [System.Windows.Forms.MessageBox]::Show("Este programa necesita Revit $REVIT_MINIMO o mas nuevo (2023, 2024, 2025 o 2026).`n`n$hay`n`nEl programa no puede iniciar.", 'Generador de cortes', 'OK', 'Warning') | Out-Null
  return
}

# ============================== VENTANA ==============================
$fuente  = New-Object System.Drawing.Font('Segoe UI', 10)
$fuenteB = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Generador de cortes  -  secciones de Revit + nube de puntos a AutoCAD  (Quinta Heeren)' + $(if ($env:CN_VERSION) { '   -   version ' + $env:CN_VERSION } else { '' })
$form.Size = New-Object System.Drawing.Size(1000, 820)
$form.StartPosition = 'CenterScreen'; $form.Font = $fuente
$form.MinimumSize = New-Object System.Drawing.Size(920, 740)
function Etiqueta($txt, $x, $y, $w, $h, $negrita) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $txt; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, $h)
  if ($negrita) { $l.Font = $fuenteB }
  $form.Controls.Add($l); $l
}
function Boton($txt, $x, $y, $w, $h) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $txt; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
  $form.Controls.Add($b); $b
}
function Combo($items, $sel, $x, $y, $w) {
  $c = New-Object System.Windows.Forms.ComboBox
  $c.DropDownStyle = 'DropDownList'; $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($w, 26)
  foreach ($i in $items) { [void]$c.Items.Add([string]$i) }
  $c.SelectedItem = [string]$sel; if ($c.SelectedIndex -lt 0) { $c.SelectedIndex = 0 }
  $form.Controls.Add($c); $c
}
$lblRevit = Etiqueta 'Buscando Revit...' 15 12 760 26 $true
$lblRevit.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold); $lblRevit.ForeColor = [System.Drawing.Color]::DarkSlateBlue
$btnAyuda = Boton 'Como hago un corte?' 785 10 190 30
$lblGuia = Etiqueta 'En Revit haz, por cada corte, DOS secciones sobre la misma linea: una corta (unos 10 cm = linea de corte) y otra hasta el fondo. Aparecen aqui solas.' 15 42 960 22 $false
$lblGuia.ForeColor = [System.Drawing.Color]::DimGray
$lista = New-Object System.Windows.Forms.ListView
$lista.Location = New-Object System.Drawing.Point(15, 68); $lista.Size = New-Object System.Drawing.Size(960, 300)
$lista.View = 'Details'; $lista.CheckBoxes = $true; $lista.FullRowSelect = $true; $lista.GridLines = $true
[void]$lista.Columns.Add('Nombre del corte', 170); [void]$lista.Columns.Add('Secciones de Revit', 230); [void]$lista.Columns.Add('Largo (m)', 80)
[void]$lista.Columns.Add('Linea de corte (m)', 120); [void]$lista.Columns.Add('Fondo (m)', 85); [void]$lista.Columns.Add('Estado', 250)
$form.Controls.Add($lista)
[void](Etiqueta 'Calidad:' 15 381 62 22 $true)
$cmbPpp = Combo @('300', '600', '1200') $PPP 80 378 70
[void](Etiqueta 'ppp  a escala  1 :' 158 381 120 22 $false)
$cmbEsc = Combo @('20', '25', '50', '75', '100', '200') $ESCALA 280 378 70
$lblPix = Etiqueta '' 360 381 300 22 $false; $lblPix.ForeColor = [System.Drawing.Color]::DimGray
$btnHerr = Boton 'Herramientas...' 785 375 190 30
# herramientas poco usadas: en un menu (los botones quedan ocultos y el menu los dispara)
$btnLas = Boton 'Convertir .las/.laz a .rcp' 0 0 10 10; $btnVinc = Boton 'Vincular nube en Revit' 0 0 10 10
$btnReinst = Boton 'Reinstalar complemento de Revit' 0 0 10 10; $btnNube = Boton 'Cambiar nube...' 0 0 10 10
foreach ($b in $btnLas, $btnVinc, $btnReinst, $btnNube) { $b.Visible = $false }
$menuHerr = New-Object System.Windows.Forms.ContextMenuStrip
$menuHerr.Font = $fuente
function Disparar($b) { $b.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic, Instance').Invoke($b, @([EventArgs]::Empty)) | Out-Null }
foreach ($par in @(@('Convertir nube .las / .laz a .rcp (para Revit)', $btnLas), @('Vincular una nube .rcp / .rcs en Revit', $btnVinc), @('Reinstalar el complemento de Revit', $btnReinst))) {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem($par[0]); $mi.Tag = $par[1]
  $mi.Add_Click({ param($s, $e) Disparar $s.Tag })
  [void]$menuHerr.Items.Add($mi)
}
$btnHerr.Add_Click({ $menuHerr.Show($btnHerr, (New-Object System.Drawing.Point(0, $btnHerr.Height))) })
$btnGen = Boton 'GENERAR CORTES  (desde Revit)' 15 414 690 56
$btnTiff = Boton 'Ya tengo los TIFF: pasar a AutoCAD' 715 414 260 56
$btnTiff.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnGen.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$btnGen.BackColor = [System.Drawing.Color]::FromArgb(46, 139, 87); $btnGen.ForeColor = [System.Drawing.Color]::White; $btnGen.FlatStyle = 'Flat'
$barra = New-Object System.Windows.Forms.ProgressBar
$barra.Location = New-Object System.Drawing.Point(15, 480); $barra.Size = New-Object System.Drawing.Size(960, 22)
$form.Controls.Add($barra)
$lblPaso = Etiqueta 'Listo para empezar.' 15 510 960 22 $true
$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(15, 535); $log.Size = New-Object System.Drawing.Size(960, 183)
$log.Multiline = $true; $log.ScrollBars = 'Vertical'; $log.ReadOnly = $true; $log.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($log)
$btnTif = Boton 'Abrir carpeta TIFF' 15 728 220 36
$btnDwg = Boton 'Abrir carpeta CORTES DWG' 245 728 220 36
$btnSalir = Boton 'Cerrar' 855 728 120 36
foreach ($c in $lista, $btnGen, $barra, $lblPaso, $lblRevit) { $c.Anchor = 'Top, Left, Right' }
foreach ($c in $btnAyuda, $btnHerr, $btnTiff) { $c.Anchor = 'Top, Right' }; $lblGuia.Anchor = 'Top, Left, Right'; $log.Anchor = 'Top, Bottom, Left, Right'
foreach ($c in $btnTif, $btnDwg) { $c.Anchor = 'Bottom, Left' }; $btnSalir.Anchor = 'Bottom, Right'
function PixelElegido { 0.0254 / [double]$cmbPpp.SelectedItem * [double]$cmbEsc.SelectedItem }
function MostrarPixel { $lblPix.Text = ('= pixel de {0:N1} mm en la realidad' -f ((PixelElegido) * 1000)) }

# ============================== FUNCIONES ==============================
function Log([string]$s) {
  $log.AppendText($s + "`r`n")
  foreach ($l in [CNLog]::Sacar()) { if ($l.Trim()) { $log.AppendText('   ' + $l.Trim() + "`r`n") } }
}
function Paso([string]$s) { $lblPaso.Text = $s; Log $s; [System.Windows.Forms.Application]::DoEvents() }
function Ocupado([int]$ms) { $t = [DateTime]::Now.AddMilliseconds($ms); while ([DateTime]::Now -lt $t) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 } }
function EsperarHilo($h) { while ($h.IsAlive) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }; if ([CNBg]::Error) { throw [CNBg]::Error } }
function EsperarProc($p) { while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150 } }
function CC([string[]]$a, [string]$logf) {
  $arg = @('-SILENT', '-NO_TIMESTAMP', '-AUTO_SAVE', 'OFF', '-LOG_FILE', "`"$logf`"") + $a
  $p = Start-Process -FilePath $CLOUDCOMPARE -ArgumentList ($arg -join ' ') -WorkingDirectory $Tmp -PassThru -WindowStyle Hidden
  EsperarProc $p
}
function Hallar([string]$nombre) {
  for ($i = 0; $i -lt 40; $i++) {
    foreach ($d in @($Tmp, $Root, (Split-Path $NUBE -Parent))) {
      $g = Get-ChildItem -LiteralPath $d -Filter "$nombre*" -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $nombre -or $_.Name -eq "$($nombre)_0" } | Select-Object -First 1
      if ($g) {
        $dst = Join-Path $Tmp $nombre
        if ($g.FullName -ne $dst) { Move-Item -LiteralPath $g.FullName -Destination $dst -Force }
        return $dst
      }
    }
    Ocupado 500
  }
  return $null
}
# Rasteriza una seccion (mirando como en Revit) y deja el TIF de CloudCompare en _temp\raw_<tag>.tif
function VistaRaw($c, [double]$paso, [string]$sub, [string]$tag) {
  $giro = Join-Path $Tmp "giro_$tag.txt"
  [IO.File]::WriteAllText($giro, [CNRev]::Giro($c, 1), [Text.Encoding]::ASCII)
  $caja = [CNRev]::CajaGirada($c, 1, $c.Fondo, $c.Zmin, $c.Zmax)
  $t0 = Get-Date
  CC @('-O', (Q $sub), '-APPLY_TRANS', (Q $giro), '-CROP', $caja,
       '-RASTERIZE', '-GRID_STEP', (F $paso), '-VERT_DIR', '0', '-PROJ', 'MIN', '-EMPTY_FILL', 'INTERP',
       '-MAX_EDGE_LENGTH', (F $RELLENO), '-OUTPUT_RASTER_RGB') (Join-Path $Tmp "log_$tag.txt")
  $tif = $null
  for ($i = 0; $i -lt 20 -and -not $tif; $i++) {
    $tif = Get-ChildItem -LiteralPath $Tmp, $Root -Filter '*RASTER*.tif' -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -ge $t0.AddSeconds(-2) -and $_.Length -ge 1024 } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $tif) { Ocupado 500 }
  }
  Get-ChildItem -LiteralPath $Tmp, $Root -Filter '*RASTER*.tif' -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 1024 } | Remove-Item -Force -ErrorAction SilentlyContinue
  if (-not $tif) { return $null }
  $dst = Join-Path $Tmp "raw_$tag.tif"
  Move-Item -LiteralPath $tif.FullName -Destination $dst -Force
  return $dst
}
function LeerNombres {
  $h = @{}
  if (Test-Path -LiteralPath $NombresTxt) { foreach ($l in [IO.File]::ReadAllLines($NombresTxt)) { $i = $l.IndexOf('='); if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) } } }
  $h
}
function GuardarNombre([string]$clave, [string]$nombre) {
  $h = LeerNombres; $h[$clave] = $nombre
  [IO.File]::WriteAllLines($NombresTxt, [string[]]@($h.Keys | ForEach-Object { "$_=$($h[$_])" }))
}
function Marca($p) { Join-Path $Tmp ('hecho_' + ($p.Clave -replace '[^A-Za-z0-9.-]', '_') + '.txt') }
function YaHecho($p, [string]$nombre) {
  if (-not $nombre) { return $false }
  $m = Marca $p
  (Test-Path -LiteralPath $m) -and ((Get-Content -LiteralPath $m -Raw).Trim() -eq ([CNSec]::Firma($p) + '|' + $nombre)) -and (Test-Path -LiteralPath (Join-Path $DwgDir "Corte $nombre.dwg"))
}
function PedirNombre($p, [string]$actual) {
  $msg = "Nombre del corte formado por:`n`n   $($p.Secciones)`n`n(asi se llamara el DWG:  Corte <nombre>.dwg)"
  $def = if ($actual) { $actual } else { $p.Sugerido }
  $n = [Microsoft.VisualBasic.Interaction]::InputBox($msg, 'Nombre del corte', $def)
  [CNRev]::Limpio($n)
}

$script:pares = @(); $script:revitFecha = [DateTime]::MinValue; $script:trabajando = $false; $script:cargando = $false
# Revit abiertos ahora: @(@{Anio; Pid}) segun la carpeta de Revit.exe de cada proceso
function RevitAbiertos {
  @(Get-Process -Name Revit -ErrorAction SilentlyContinue | ForEach-Object {
    $a = 0; try { if ($_.Path -match 'Revit (\d{4})') { $a = [int]$Matches[1] } } catch {}
    if (-not $a) { try { $a = 2000 + [int]($_.MainModule.FileVersionInfo.FileMajorVersion) } catch {} }
    [pscustomobject]@{ Anio = $a; Id = $_.Id }
  })
}
function CargarRevit {
  $marcados = @{}; foreach ($it in $lista.Items) { $marcados[$it.Tag.Clave] = $it.Checked }
  $lista.Items.Clear(); $script:pares = @()
  $script:revitFecha = if (Test-Path -LiteralPath $RevitTxt) { (Get-Item -LiteralPath $RevitTxt).LastWriteTime } else { [DateTime]::MinValue }
  $abiertos = @(RevitAbiertos); $script:revitAbierto = $abiertos.Count -gt 0
  $txtRevit = if ($abiertos.Count) { (($abiertos | ForEach-Object { "Revit $($_.Anio)" } | Select-Object -Unique) -join ' + ') + ' abierto' } else { '' }
  if (-not $abiertos.Count) {
    $lblRevit.Text = 'Revit no esta abierto: abre Revit con tu proyecto (las secciones apareceran solas).'; $lblRevit.ForeColor = [System.Drawing.Color]::Firebrick
    $lblPaso.Text = 'Esperando a Revit...'; return
  }
  $viejo = @($abiertos | Where-Object { $_.Anio -and $_.Anio -lt $REVIT_MINIMO })
  if ($viejo.Count -eq $abiertos.Count) {
    $lblRevit.Text = "$txtRevit : esta version no sirve (hace falta Revit $REVIT_MINIMO a 2026)."; $lblRevit.ForeColor = [System.Drawing.Color]::Firebrick; return
  }
  if (-not (Test-Path -LiteralPath $RevitTxt) -or ((Get-Item -LiteralPath $RevitTxt).LastWriteTime -lt ((Get-Process -Id $abiertos[0].Id -ErrorAction SilentlyContinue).StartTime))) {
    $lblRevit.Text = "$txtRevit  -  esperando el proyecto... (si acabas de instalar el complemento, cierra y vuelve a abrir Revit)"; $lblRevit.ForeColor = [System.Drawing.Color]::DarkOrange
    $lblPaso.Text = 'Abre tu proyecto en Revit: las secciones llegan solas.'; return
  }
  $script:revitFecha = (Get-Item -LiteralPath $RevitTxt).LastWriteTime
  $cab = @([IO.File]::ReadAllLines($RevitTxt) | Where-Object { $_ -like '#*' })
  $proy = (($cab | Where-Object { $_ -like '# proyecto:*' }) -replace '^# proyecto:\s*', '') -join ''
  $nube = (($cab | Where-Object { $_ -like '# nube:*' }) -replace '^# nube:\s*', '') -join ''
  try {
    $secs = [CNRev]::Leer($RevitTxt)
    foreach ($s in $secs) { $s.Zmin = [math]::Max($s.Zmin, $Z_TOPE_MIN); $s.Zmax = [math]::Min($s.Zmax, $Z_TOPE_MAX); if ($s.Zmax -le $s.Zmin) { $s.Zmin = $Z_TOPE_MIN; $s.Zmax = $Z_TOPE_MAX } }
    $script:pares = @([CNSec]::Agrupar($secs, $ROJO_MAX, $ROJO_AUTO, 0.05))
  }
  catch { $lblRevit.Text = "No se pudieron leer las secciones: $($_.Exception.Message)"; return }
  $lblRevit.Text = ("{0}  -  proyecto: {1}  -  nube: {2}  -  {3} corte(s)" -f $txtRevit, $proy, $nube, $script:pares.Count)
  if ($nube -eq 'SIN NUBE VINCULADA') { $lblRevit.ForeColor = [System.Drawing.Color]::Firebrick } else { $lblRevit.ForeColor = [System.Drawing.Color]::DarkSlateBlue }
  $nom = LeerNombres
  foreach ($p in $script:pares) {
    $n = $nom[$p.Clave]
    $k = if ($p.Fondo) { $p.Fondo } else { $p.Rojo }
    $it = New-Object System.Windows.Forms.ListViewItem($(if ($n) { $n } else { '(sin nombre)' }))
    [void]$it.SubItems.Add($p.Secciones); [void]$it.SubItems.Add(('{0:N2}' -f $k.Largo))
    [void]$it.SubItems.Add(('{0:N2}{1}' -f $p.Rojo.Fondo, $(if ($p.RojoAuto) { ' (auto)' } else { '' })))
    [void]$it.SubItems.Add($(if ($p.Fondo) { '{0:N2}' -f $p.Fondo.Fondo } else { '-' }))
    if (YaHecho $p $n) { [void]$it.SubItems.Add("Ya generado: Corte $n.dwg"); $it.Checked = $false }
    else { [void]$it.SubItems.Add('Nuevo / cambiado: se generara'); $it.Checked = $true }
    if ($marcados.ContainsKey($p.Clave)) { $it.Checked = $marcados[$p.Clave] }
    $it.Tag = $p; [void]$lista.Items.Add($it)
  }
  if ($script:pares.Count -eq 0) { $lblPaso.Text = 'El proyecto de Revit no tiene secciones todavia.' }
  else { $lblPaso.Text = "$($script:pares.Count) corte(s) detectados. Marca los que quieras y pulsa GENERAR CORTES." }
}

function Letra([int]$n) { $s = ''; $n++; while ($n -gt 0) { $n--; $s = ([string][char](65 + ($n % 26))) + $s; $n = [int][math]::Floor($n / 26) }; $s }
# Lista para poner nombre a todos los cortes marcados. Devuelve los nombres (en orden) o $null si se cancela.
function PedirNombres($items) {
  $script:dlgItems = @($items)
  $script:dlgF = New-Object System.Windows.Forms.Form
  $script:dlgF.Text = 'Nombres de los cortes'; $script:dlgF.Size = New-Object System.Drawing.Size(820, 560); $script:dlgF.StartPosition = 'CenterParent'; $script:dlgF.Font = $fuente
  $script:dlgF.MinimizeBox = $false; $script:dlgF.MaximizeBox = $false
  $l = New-Object System.Windows.Forms.Label; $l.Location = New-Object System.Drawing.Point(12, 10); $l.Size = New-Object System.Drawing.Size(780, 40)
  $l.Text = "Ponle nombre a cada corte. Cada uno sera un DWG:  Corte <nombre>.dwg`nUsa un boton para numerarlos de una vez, o escribe en la columna NOMBRE."
  $script:dlgF.Controls.Add($l)
  $b1 = New-Object System.Windows.Forms.Button; $b1.Text = 'Letras  A, B, C...'; $b1.Location = New-Object System.Drawing.Point(12, 55); $b1.Size = New-Object System.Drawing.Size(150, 30); $script:dlgF.Controls.Add($b1)
  $b2 = New-Object System.Windows.Forms.Button; $b2.Text = 'Numeros  1, 2, 3...'; $b2.Location = New-Object System.Drawing.Point(170, 55); $b2.Size = New-Object System.Drawing.Size(150, 30); $script:dlgF.Controls.Add($b2)
  $b3 = New-Object System.Windows.Forms.Button; $b3.Text = 'Nombres de Revit'; $b3.Location = New-Object System.Drawing.Point(328, 55); $b3.Size = New-Object System.Drawing.Size(150, 30); $script:dlgF.Controls.Add($b3)
  $le = New-Object System.Windows.Forms.Label; $le.Text = 'empezar en:'; $le.Location = New-Object System.Drawing.Point(490, 61); $le.Size = New-Object System.Drawing.Size(85, 22); $script:dlgF.Controls.Add($le)
  $script:dlgTe = New-Object System.Windows.Forms.TextBox; $script:dlgTe.Text = 'A'; $script:dlgTe.Location = New-Object System.Drawing.Point(578, 58); $script:dlgTe.Size = New-Object System.Drawing.Size(60, 26); $script:dlgF.Controls.Add($script:dlgTe)
  $script:dlgG = New-Object System.Windows.Forms.DataGridView
  $script:dlgG.Location = New-Object System.Drawing.Point(12, 95); $script:dlgG.Size = New-Object System.Drawing.Size(780, 370)
  $script:dlgG.AllowUserToAddRows = $false; $script:dlgG.AllowUserToDeleteRows = $false; $script:dlgG.RowHeadersVisible = $false; $script:dlgG.SelectionMode = 'CellSelect'
  [void]$script:dlgG.Columns.Add('sec', 'Secciones de Revit'); [void]$script:dlgG.Columns.Add('lar', 'Largo (m)'); [void]$script:dlgG.Columns.Add('nom', 'NOMBRE')
  $script:dlgG.Columns[0].Width = 420; $script:dlgG.Columns[1].Width = 90; $script:dlgG.Columns[2].Width = 240; $script:dlgG.Columns[0].ReadOnly = $true; $script:dlgG.Columns[1].ReadOnly = $true
  $script:dlgG.Columns[2].DefaultCellStyle.BackColor = [System.Drawing.Color]::LightYellow
  $nom = LeerNombres
  foreach ($it in $items) {
    $p = $it.Tag; $k = if ($p.Fondo) { $p.Fondo } else { $p.Rojo }
    $n = $nom[$p.Clave]; if (-not $n) { $n = '' }
    [void]$script:dlgG.Rows.Add($p.Secciones, ('{0:N2}' -f $k.Largo), $n)
  }
  $script:dlgF.Controls.Add($script:dlgG)
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Aceptar y generar'; $ok.Location = New-Object System.Drawing.Point(530, 475); $ok.Size = New-Object System.Drawing.Size(160, 34); $script:dlgF.Controls.Add($ok)
  $ca = New-Object System.Windows.Forms.Button; $ca.Text = 'Cancelar'; $ca.Location = New-Object System.Drawing.Point(700, 475); $ca.Size = New-Object System.Drawing.Size(92, 34); $ca.DialogResult = 'Cancel'; $script:dlgF.Controls.Add($ca)
  $script:dlgF.CancelButton = $ca
  $b1.Add_Click({ $s = $script:dlgTe.Text.Trim().ToUpperInvariant(); $i0 = 0; if ($s -match '^[A-Z]+$') { $i0 = 0; foreach ($ch in $s.ToCharArray()) { $i0 = $i0 * 26 + ([int]$ch - 64) }; $i0-- }; for ($r = 0; $r -lt $script:dlgG.Rows.Count; $r++) { $script:dlgG.Rows[$r].Cells[2].Value = Letra ($i0 + $r) } })
  $b2.Add_Click({ $i0 = 1; [void][int]::TryParse($script:dlgTe.Text.Trim(), [ref]$i0); for ($r = 0; $r -lt $script:dlgG.Rows.Count; $r++) { $script:dlgG.Rows[$r].Cells[2].Value = [string]($i0 + $r) } })
  $b3.Add_Click({ for ($r = 0; $r -lt $script:dlgG.Rows.Count; $r++) { $script:dlgG.Rows[$r].Cells[2].Value = $script:dlgItems[$r].Tag.Sugerido } })
  $script:nombresOk = $null
  $ok.Add_Click({
    $script:dlgG.EndEdit() | Out-Null
    $res = @(); $vistos = @{}
    for ($r = 0; $r -lt $script:dlgG.Rows.Count; $r++) {
      $n = [CNRev]::Limpio([string]$script:dlgG.Rows[$r].Cells[2].Value)
      if (-not $n) { [System.Windows.Forms.MessageBox]::Show("Falta el nombre del corte de la fila $($r + 1).", 'Nombres de los cortes') | Out-Null; return }
      if ($vistos.ContainsKey($n.ToUpperInvariant())) { [System.Windows.Forms.MessageBox]::Show("El nombre '$n' esta repetido.", 'Nombres de los cortes') | Out-Null; return }
      $vistos[$n.ToUpperInvariant()] = $true; $res += $n
    }
    $script:nombresOk = $res; $script:dlgF.DialogResult = 'OK'; $script:dlgF.Close()
  })
  [void]$script:dlgF.ShowDialog($form)
  return $script:nombresOk
}

# Pide al complemento 'Cortes nube' (dentro de Revit) que rasterice los puntos de la nube de cada seccion.
# $lineas: una por imagen. Devuelve un resultado por linea, en orden.
function PedirRevit([string[]]$lineas) {
  $carp = Split-Path $RevitTxt -Parent; New-Item -ItemType Directory -Force -Path $carp | Out-Null
  $ped = Join-Path $carp 'exportar_nube.txt'; $listo = Join-Path $carp 'nube_listo.txt'
  Remove-Item -LiteralPath $listo -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllLines("$ped.tmp", $lineas); Move-Item -LiteralPath "$ped.tmp" -Destination $ped -Force
  $t0 = Get-Date
  while (Test-Path -LiteralPath $ped) {
    [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200
    if (((Get-Date) - $t0).TotalSeconds -gt 25) {
      Remove-Item -LiteralPath $ped -Force -ErrorAction SilentlyContinue
      throw "Revit no respondio. Deja abierto Revit con tu proyecto (complemento 'Cortes nube' cargado) y vuelve a pulsar GENERAR."
    }
  }
  while (-not (Test-Path -LiteralPath $listo)) {
    [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 300
    $s = [int]((Get-Date) - $t0).TotalSeconds; $lblPaso.Text = ("Revit esta leyendo la nube de las secciones ... {0}:{1:00}  (no uses Revit mientras tanto)" -f [int][math]::Floor($s / 60), ($s % 60))
    if (((Get-Date) - $t0).TotalMinutes -gt 30) { throw 'Revit tardo demasiado en leer la nube.' }
  }
  Start-Sleep -Milliseconds 300
  $r = @(Get-Content -LiteralPath $listo | Where-Object { $_.Trim() } | ForEach-Object { $q = $_.Split('|', 3); [pscustomobject]@{ Ruta = $q[0]; Ok = ($q[1] -eq 'OK'); Txt = $q[2] } })
  Remove-Item -LiteralPath $listo -Force -ErrorAction SilentlyContinue
  return ,$r
}

# Arma un DWG por corte con AutoCAD (imagenes incrustadas y agrupadas). $nombres: cortes a armar; $imgDir: carpeta
# con Corte_<nombre>_revit_conjunto.tif / _rojo.tif; $px: pixel final (0 = el del TIFF). Devuelve los nombres listos.
function ArmarDwg([string[]]$nombres, [string]$imgDir, [double]$px) {
  Paso 'Preparando las imagenes para AutoCAD...'
  [CNPrep]::SinGeo.Clear()
  EsperarHilo ([CNBg]::Build($Root, $imgDir, $Png, $px, $px, $MAX_PX, $BAJA, $SEPARACION, ($nombres -join ','), $DwgDir))
  foreach ($a in [CNPrep]::SinGeo) { Log "   AVISO: $a" }
  $ok = @()
  foreach ($L in [CNBg]::Letras) {
    $dwg = Join-Path $DwgDir "Corte $L.dwg"
    if (Test-Path -LiteralPath $dwg) {
      try { $fs = [IO.File]::Open($dwg, 'Open', 'ReadWrite', 'None'); $fs.Close() }
      catch { Log "Corte $L : 'Corte $L.dwg' esta abierto en AutoCAD. Cierralo y vuelve a intentar."; continue }
    }
    Paso "Armando 'Corte $L.dwg' en AutoCAD (se abre y se cierra solo; no copies ni pegues nada)..."
    $t0 = Get-Date
    $pr = Start-Process -FilePath $AUTOCAD -ArgumentList "/nologo /b `"$(Join-Path $Png "armar_$L.scr")`"" -PassThru
    EsperarProc $pr
    if ((Test-Path -LiteralPath $dwg) -and ((Get-Item -LiteralPath $dwg).LastWriteTime -ge $t0.AddSeconds(-2))) {
      Log ("   OK  Corte {0}.dwg  ({1} MB)" -f $L, [math]::Round((Get-Item -LiteralPath $dwg).Length / 1MB, 1))
      Remove-Item -LiteralPath (Join-Path $DwgDir "Corte $L.bak") -Force -ErrorAction SilentlyContinue
      $ok += $L
    } else { Log "   ERROR: AutoCAD no guardo 'Corte $L.dwg'" }
    $barra.Value = [math]::Min($barra.Maximum, $barra.Value + 1)
  }
  return ,$ok
}

# Atajo: TIFF que ya tienes -> DWG (sin Revit). Los Corte_<n>_revit_conjunto/_rojo se juntan en un DWG por corte;
# cualquier otro TIFF va solo en su propio DWG (si no esta georreferenciado se escala con sus ppp y la escala elegida).
function TiffACad {
  if (-not $AUTOCAD) { throw 'No encuentro AutoCAD instalado.' }
  $d = New-Object System.Windows.Forms.OpenFileDialog
  $d.Title = 'Elige los TIFF de tus cortes (puedes elegir varios)'; $d.Filter = 'Imagenes TIFF (*.tif;*.tiff)|*.tif;*.tiff'; $d.Multiselect = $true
  if (Test-Path -LiteralPath $TifDir) { $d.InitialDirectory = $TifDir }
  if ($d.ShowDialog() -ne 'OK') { return }
  $dir = Join-Path $Tmp 'tiff_a_autocad'
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  foreach ($x in $dir, $DwgDir, $Png) { New-Item -ItemType Directory -Force -Path $x | Out-Null }
  [CNPrep]::Escala = [double]$cmbEsc.SelectedItem; [CNPrep]::PxSinGeo = PixelElegido
  $nombres = @()
  # si eliges solo una de las dos imagenes de un corte del generador, se agrega la otra (con fondo / seccion roja)
  $archivos = New-Object System.Collections.Generic.List[string]
  foreach ($f in $d.FileNames) {
    if (-not $archivos.Contains($f)) { $archivos.Add($f) }
    if ([IO.Path]::GetFileNameWithoutExtension($f) -match '^(Corte_.+_revit_)(conjunto|rojo)$') {
      $otro = Join-Path (Split-Path $f -Parent) ($Matches[1] + $(if ($Matches[2] -eq 'rojo') { 'conjunto' } else { 'rojo' }) + [IO.Path]::GetExtension($f))
      if ((Test-Path -LiteralPath $otro) -and -not $archivos.Contains($otro)) { $archivos.Add($otro) }
    }
  }
  foreach ($f in $archivos) {
    $b = [IO.Path]::GetFileNameWithoutExtension($f)
    if ($b -match '^Corte_(.+)_revit_(conjunto|rojo)$') { $n = $Matches[1]; $k = $Matches[2] }
    else { $n = ($b -replace '^Corte[_ ]', '') -replace '[\\/:*?"<>|]', '_'; $k = 'conjunto' }
    $dst = Join-Path $dir "Corte_$($n)_revit_$k.tif"
    if (Test-Path -LiteralPath $dst) { Log "   (repetido, se ignora) $f"; continue }
    Copy-Item -LiteralPath $f -Destination $dst -Force
    if ($nombres -notcontains $n) { $nombres += $n }
  }
  if (-not $nombres.Count) { return }
  $script:trabajando = $true
  foreach ($c in $btnGen, $btnTiff, $lista, $btnHerr) { $c.Enabled = $false }
  try {
    $barra.Maximum = $nombres.Count + 1; $barra.Value = 0
    Log "TIFF a AutoCAD: $($nombres.Count) corte(s): $($nombres -join ', ')"
    $ok = ArmarDwg $nombres $dir 0
    $barra.Value = $barra.Maximum
    Paso ("TERMINADO: {0} de {1} DWG en la carpeta CORTES DWG." -f $ok.Count, $nombres.Count)
    [System.Media.SystemSounds]::Asterisk.Play()
  } catch { Log "ERROR: $($_.Exception.Message)"; Paso 'No se pudo terminar. Revisa los mensajes.' }
  finally {
    foreach ($c in $btnGen, $btnTiff, $lista, $btnHerr) { $c.Enabled = $true }
    $script:trabajando = $false
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Generar {
  $sel = @($lista.Items | Where-Object { $_.Checked })
  if ($sel.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Marca al menos un corte en la lista.', 'Generador de cortes') | Out-Null; return }
  if (-not $AUTOCAD) { throw 'No encuentro AutoCAD instalado.' }
  foreach ($d in $TifDir, $DwgDir, $Tmp, $Png) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  $nombres = PedirNombres $sel
  if (-not $nombres) { Paso 'Cancelado.'; return }
  for ($i = 0; $i -lt $sel.Count; $i++) { GuardarNombre $sel[$i].Tag.Clave $nombres[$i]; $sel[$i].Text = $nombres[$i] }
  $px = PixelElegido; $ppp = [double]$cmbPpp.SelectedItem
  $pasoRojo = [math]::Min(0.001, $px)
  Log ("Calidad: {0} ppp a 1:{1}  ->  pixel {2:N2} mm" -f $ppp, $cmbEsc.SelectedItem, ($px * 1000))
  $sel = @($sel | Where-Object { $_.Checked })
  $total = 3; $hecho = 0; $barra.Maximum = $total; $barra.Value = 0
  # 1) Revit lee los puntos de la nube de cada seccion (corta y de fondo) y deja TIFF crudos - una sola vez para todos
  $ped = @(); $lin = @()
  foreach ($it in $sel) {
    $p = $it.Tag; $k = $it.Text -replace '[^A-Za-z0-9_-]', '_'
    $rr = Join-Path $Tmp "raw_$($k)_rojo.tif"
    $ped += [pscustomobject]@{ It = $it; Tipo = 'rojo'; Ruta = $rr }; $lin += [CNSec]::PedidoNube($p.Rojo, $p.Rojo.Dx, $p.Rojo.Dy, $pasoRojo, 0.004, $rr)
    if ($p.Fondo) {
      $rf = Join-Path $Tmp "raw_$($k)_fondo.tif"
      $ped += [pscustomobject]@{ It = $it; Tipo = 'fondo'; Ruta = $rf }; $lin += [CNSec]::PedidoNube($p.Fondo, $p.Rojo.Dx, $p.Rojo.Dy, $px, ($RELLENO / 2), $rf)
    }
    $it.SubItems[5].Text = 'Esperando a Revit...'
  }
  foreach ($q in $ped) { Remove-Item -LiteralPath $q.Ruta -Force -ErrorAction SilentlyContinue }
  Paso "Revit esta leyendo la nube de $($ped.Count) seccion(es)..."
  try { $res = PedirRevit $lin }
  catch { foreach ($it in $sel) { $it.SubItems[5].Text = "ERROR: $($_.Exception.Message)" }; Log "ERROR: $($_.Exception.Message)"; Paso 'No se genero ningun corte. Revisa los mensajes.'; return }
  for ($i = 0; $i -lt $ped.Count; $i++) {
    $q = $ped[$i]; $r = $res | Where-Object { $_.Ruta -eq $q.Ruta } | Select-Object -First 1
    $ok = $r -and $r.Ok -and (Test-Path -LiteralPath $q.Ruta)
    $q | Add-Member -NotePropertyName Ok -NotePropertyValue $ok
    $q | Add-Member -NotePropertyName Txt -NotePropertyValue $(if ($r) { $r.Txt } else { 'Revit no devolvio la imagen' })
    Log "   $($q.It.Text) ($($q.Tipo)): $($q.Txt)"
  }
  $barra.Value = ++$hecho
  $listos = @()
  foreach ($it in $sel) {
    $p = $it.Tag; $n = $it.Text
    $it.SubItems[5].Text = 'Trabajando...'; $t0 = Get-Date
    $qr = $ped | Where-Object { $_.It -eq $it -and $_.Tipo -eq 'rojo' } | Select-Object -First 1
    $qf = $ped | Where-Object { $_.It -eq $it -and $_.Tipo -eq 'fondo' } | Select-Object -First 1
    try {
      Get-ChildItem -LiteralPath $TifDir -Filter "Corte_$($n)_*.tif" -ErrorAction SilentlyContinue | Remove-Item -Force
      if (-not $qr.Ok) { throw "no se pudo leer la seccion de corte: $($qr.Txt)" }
      $rawF = if ($qf -and $qf.Ok) { $qf.Ruta } else { $null }
      if ($qf -and -not $qf.Ok) { Log "   la vista con fondo fallo ($($qf.Txt)): solo se hara la seccion" }
      Paso "Corte $n : uniendo la linea de corte con el fondo..."
      $tc = if ($rawF) { Join-Path $TifDir "Corte_$($n)_revit_conjunto.tif" } else { $null }
      $tr = Join-Path $TifDir "Corte_$($n)_revit_rojo.tif"
      EsperarHilo ([CNBg]::Componer($rawF, $qr.Ruta, $tc, $tr, $px, $ppp))
      Log "   imagenes de $([CNBg]::Info) pixeles ($ppp ppp a 1:$($cmbEsc.SelectedItem))"
      foreach ($f in @($qr.Ruta, $rawF)) { if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
      $it.SubItems[5].Text = ('Imagenes listas ({0:N0} s)' -f ((Get-Date) - $t0).TotalSeconds)
      $listos += $it
    } catch {
      $it.SubItems[5].Text = "ERROR: $($_.Exception.Message)"; Log "Corte $n : ERROR $($_.Exception.Message)"
    }
  }
  $barra.Value = ++$hecho
  if ($listos.Count -eq 0) { Paso 'No se genero ningun corte. Revisa los mensajes.'; return }
  $hechos = ArmarDwg @($listos | ForEach-Object { $_.Text }) $TifDir $px
  foreach ($it in $listos) {
    if ($hechos -contains $it.Text) {
      [IO.File]::WriteAllText((Marca $it.Tag), ([CNSec]::Firma($it.Tag) + '|' + $it.Text))
      $it.SubItems[5].Text = "LISTO: Corte $($it.Text).dwg"; $it.Checked = $false
    }
  }
  $barra.Value = $barra.Maximum
  Paso 'TERMINADO. Abre la carpeta CORTES DWG con el boton de abajo.'
  [System.Media.SystemSounds]::Asterisk.Play()
}

# ============================== EVENTOS ==============================
$btnAyuda.Add_Click({
  [System.Windows.Forms.MessageBox]::Show(
    "COMO HACER UN CORTE EN REVIT`n`n" +
    "1. En la planta donde se ve la nube: Vista > Seccion. Clic en el inicio y en el final del corte.`n" +
    "2. En sus Propiedades pon 'Desfase de delimitacion lejano' corto (p. ej. 0.10 m):`n" +
    "   esta seccion es la LINEA DE CORTE (si quieres, pinta la nube de rojo en esa vista).`n" +
    "3. Haz OTRA seccion sobre la MISMA linea (copia la primera) y ponle un desfase lejano grande`n" +
    "   (hasta el fondo que quieras ver): esta es la vista CON FONDO.`n" +
    "4. Las dos secciones aparecen solas en esta ventana como UN corte.`n" +
    "5. Pulsa GENERAR CORTES: te pedira el nombre y hara el DWG a escala real.`n`n" +
    "Si solo haces una seccion larga, la linea de corte se saca sola con 10 cm.`n" +
    "La flecha de la seccion manda: la vista mira hacia donde mira la seccion en Revit.", 'Como hago un corte?', 'OK', 'Information') | Out-Null
})
$lista.Add_DoubleClick({
  if ($script:trabajando -or -not $lista.SelectedItems.Count) { return }
  $it = $lista.SelectedItems[0]; $p = $it.Tag
  $n = PedirNombre $p $(if ($it.Text -ne '(sin nombre)') { $it.Text } else { '' })
  if ($n) { GuardarNombre $p.Clave $n; $it.Text = $n; $it.Checked = -not (YaHecho $p $n); $it.SubItems[5].Text = $(if (YaHecho $p $n) { "Ya generado: Corte $n.dwg" } else { 'Nuevo / cambiado: se generara' }) }
})
$btnReinst.Add_Click({
  $r = InstalarComplemento $true
  $m = if ($r.Hechos.Count) { "Complemento instalado en: $($r.Hechos -join ', ').`n`nCierra Revit (guarda tu trabajo) y vuelve a abrirlo. Si pregunta, elige 'Cargar siempre'." } else { 'No se instalo en ningun Revit.' }
  if ($r.Errores.Count) { $m += "`n`n" + ($r.Errores -join "`n") }
  [System.Windows.Forms.MessageBox]::Show($m, 'Complemento de Revit') | Out-Null
})
function MostrarNube { }
function ElegirNube([string]$ruta) {
  $script:NUBE = $ruta; Set-Variable -Name NUBE -Value $ruta -Scope Global
  [IO.File]::WriteAllText($NubeTxt, $ruta); MostrarNube; Log "Nube para los cortes: $ruta"
}
$btnNube.Add_Click({
  $d = New-Object System.Windows.Forms.OpenFileDialog
  $d.Title = 'Nube de puntos que se usara para sacar los cortes (la misma que esta en Revit)'
  $d.Filter = 'Nubes de puntos (*.bin;*.las;*.laz;*.e57)|*.bin;*.las;*.laz;*.e57|Todos (*.*)|*.*'
  if ($NUBE) { $d.InitialDirectory = Split-Path $NUBE -Parent }
  if ($d.ShowDialog() -eq 'OK') { ElegirNube $d.FileName }
})
function HallarDecap {
  foreach ($dir in @(Get-ChildItem 'C:\Program Files\Autodesk' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*ReCap*' })) {
    $f = Get-ChildItem -LiteralPath $dir.FullName -Filter 'DeCap.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
  }
  return $null
}
function Decap([string]$exe, [string]$salida, [string]$nombre, [string]$nube, [string]$logf) {
  $arg = "--importWithLicense `"$salida`" `"$nombre`" --unify `"$nube`""
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = $arg; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.WorkingDirectory = Split-Path $exe -Parent
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
  $t0 = Get-Date
  while (-not $p.HasExited) {
    [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 300
    $s = [int]((Get-Date) - $t0).TotalSeconds; $lblPaso.Text = ("Convirtiendo la nube a .rcp ... {0}:{1:00}  (puede tardar varios minutos)" -f [int][math]::Floor($s / 60), ($s % 60))
  }
  try { [IO.File]::WriteAllText($logf, "DeCap $arg`r`n`r`n" + $out.Result + "`r`n" + $err.Result) } catch {}
  $r = Get-ChildItem -LiteralPath $salida -Filter "$nombre*.rcp" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $r) { $r = Get-ChildItem -LiteralPath $salida -Recurse -Depth 2 -Include '*.rcp', '*.rcs' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0.AddSeconds(-5) } | Sort-Object @{ e = { $_.Extension -eq '.rcp' } } -Descending | Select-Object -First 1 }
  return $r
}
$btnLas.Add_Click({
  $d = New-Object System.Windows.Forms.OpenFileDialog
  $d.Title = 'Elige la nube .las / .laz / .e57 que quieres convertir a .rcp/.rcs para Revit'
  $d.Filter = 'Nubes (*.las;*.laz;*.e57)|*.las;*.laz;*.e57'
  if ($d.ShowDialog() -ne 'OK') { return }
  $nube = $d.FileName
  $exe = HallarDecap
  if (-not $exe) {
    [System.Windows.Forms.MessageBox]::Show("No encontre DeCap.exe (el conversor de Autodesk ReCap) en esta PC.`n`nRevit no lee .las/.laz directamente: hace falta Autodesk ReCap Pro instalado (incluido en la AEC Collection).", 'Convertir nube', 'OK', 'Warning') | Out-Null
    return
  }
  $salida = Split-Path $nube -Parent
  $nombre = [IO.Path]::GetFileNameWithoutExtension($nube)
  $logf = Join-Path $Tmp 'log_conversion_rcp.txt'
  New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
  $btnLas.Enabled = $false; $btnGen.Enabled = $false
  try {
    Log "Convirtiendo a .rcp (DeCap de ReCap, sin abrir ReCap): $nube"
    $rcp = Decap $exe $salida $nombre $nube $logf
    if (-not $rcp -and $nube -match '\.laz$' -and (Test-Path -LiteralPath $CLOUDCOMPARE)) {
      Log '   DeCap no acepto el .laz: lo paso primero a .las con CloudCompare...'
      Paso 'Pasando el .laz a .las...'
      Get-ChildItem -LiteralPath $Tmp -Filter 'laz_conv*' -ErrorAction SilentlyContinue | Remove-Item -Force
      CC @('-O', '-GLOBAL_SHIFT', '0', '0', '0', "`"$nube`"", '-C_EXPORT_FMT', 'LAS', '-SAVE_CLOUDS', 'FILE', 'laz_conv.las') (Join-Path $Tmp 'log_laz.txt')
      $las = Get-ChildItem -LiteralPath $Tmp -Filter 'laz_conv*' -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.las' -or $_.Name -like 'laz_conv.las*' } | Select-Object -First 1
      if ($las) {
        $tmpLas = Join-Path $Tmp ($nombre + '.las')
        Move-Item -LiteralPath $las.FullName -Destination $tmpLas -Force
        $rcp = Decap $exe $salida $nombre $tmpLas $logf
        Remove-Item -LiteralPath $tmpLas -Force -ErrorAction SilentlyContinue
      }
    }
    if (-not $rcp) {
      Log "   No se creo el .rcp. Detalle en: $logf"
      Paso 'La conversion no termino bien.'
      [System.Windows.Forms.MessageBox]::Show("No se pudo crear el .rcp.`n`nCausas habituales:`n - ReCap Pro no tiene la licencia activada en esta PC (abre ReCap una vez e inicia sesion).`n - El archivo esta danado o en un formato que ReCap no lee.`n`nDetalle en:`n$logf", 'Convertir nube', 'OK', 'Warning') | Out-Null
      return
    }
    Log "   Listo: $($rcp.FullName)  (y su carpeta con los .rcs)"
    Paso "Nube convertida: $($rcp.Name)"
    if ([System.Windows.Forms.MessageBox]::Show("Nube convertida:`n$($rcp.FullName)`n`nVincularla ahora en tu proyecto de Revit abierto (origen a origen interno)?", 'Convertir nube', 'YesNo', 'Question') -eq 'Yes') {
      New-Item -ItemType Directory -Force -Path (Split-Path $PedidoVinc -Parent) | Out-Null
      [IO.File]::WriteAllText($PedidoVinc, $rcp.FullName)
      Log "Pedido a Revit: vincular $($rcp.FullName)"
    }
  } finally { $btnLas.Enabled = $true; $btnGen.Enabled = $true }
})
$btnVinc.Add_Click({
  $d = New-Object System.Windows.Forms.OpenFileDialog
  $d.Title = 'Elige la nube indexada (.rcp o .rcs) para vincular en Revit'
  $d.Filter = 'Nube de ReCap (*.rcp;*.rcs)|*.rcp;*.rcs'
  if ($NUBE) { $d.InitialDirectory = Split-Path $NUBE -Parent }
  if ($d.ShowDialog() -ne 'OK') { return }
  New-Item -ItemType Directory -Force -Path (Split-Path $PedidoVinc -Parent) | Out-Null
  [IO.File]::WriteAllText($PedidoVinc, $d.FileName)
  Log "Pedido a Revit: vincular $($d.FileName)"
  [System.Windows.Forms.MessageBox]::Show("Listo. Ve a Revit (con tu proyecto abierto) y haz clic en la ventana:`nen unos segundos la nube queda vinculada en origen a origen interno.`n`n(Hace falta que Revit tenga el complemento 'Cortes nube' cargado.)", 'Vincular en Revit', 'OK', 'Information') | Out-Null
})
$cmbPpp.Add_SelectedIndexChanged({ MostrarPixel })
$cmbEsc.Add_SelectedIndexChanged({ MostrarPixel })
$btnTif.Add_Click({ New-Item -ItemType Directory -Force -Path $TifDir | Out-Null; Start-Process explorer.exe -ArgumentList "`"$TifDir`"" })
$btnDwg.Add_Click({ New-Item -ItemType Directory -Force -Path $DwgDir | Out-Null; Start-Process explorer.exe -ArgumentList "`"$DwgDir`"" })
$btnSalir.Add_Click({ $form.Close() })
$btnTiff.Add_Click({ if (-not $script:trabajando) { try { TiffACad } catch { Paso "ERROR: $($_.Exception.Message)" } } })
$btnGen.Add_Click({
  if ($script:trabajando) { return }
  $script:trabajando = $true
  foreach ($c in $btnGen, $lista, $btnReinst, $btnTiff) { $c.Enabled = $false }
  $btnGen.Text = 'GENERANDO...  (puedes dejarlo trabajando)'
  try { Generar } catch {
    Paso "ERROR: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show("ERROR:`n`n$($_.Exception.Message)", 'Generador de cortes', 'OK', 'Error') | Out-Null
  } finally {
    foreach ($c in $btnGen, $lista, $btnReinst, $btnTiff) { $c.Enabled = $true }
    $btnGen.Text = 'GENERAR CORTES  (desde Revit)'; $script:trabajando = $false
  }
})
$reloj = New-Object System.Windows.Forms.Timer
$reloj.Interval = 2000
$reloj.Add_Tick({
  if ($script:trabajando -or $script:cargando) { return }
  $script:cargando = $true
  try {
    $f = if (Test-Path -LiteralPath $RevitTxt) { (Get-Item -LiteralPath $RevitTxt).LastWriteTime } else { [DateTime]::MinValue }
    $hay = @(Get-Process -Name Revit -ErrorAction SilentlyContinue).Count -gt 0
    $antes = $script:revitFecha
    if ($f -ne $antes -or $hay -ne $script:revitAbierto) { CargarRevit; if ($f -ne $antes -and $antes -ne [DateTime]::MinValue -and $f -ne [DateTime]::MinValue) { Log "Revit actualizo las secciones ($('{0:HH:mm:ss}' -f $f))" } }
  } catch { } finally { $script:cargando = $false }
})
$form.Add_Shown({
  MostrarNube; MostrarPixel
  foreach ($d in $TifDir, $DwgDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  if ($env:CN_UPDATE_MSG) { Log "Actualizaciones: $env:CN_UPDATE_MSG" }
  Log "Carpetas de salida (junto al programa):  TIFF -> $TifDir   |   CORTES DWG -> $DwgDir"
  Log ("Revit en esta PC: " + (($script:revits | ForEach-Object { if ($_.Anio -ge $REVIT_MINIMO) { "Revit $($_.Anio) (ok)" } else { "Revit $($_.Anio) (muy antiguo, se ignora)" } }) -join ', '))
  [System.Windows.Forms.Application]::DoEvents()
  try {
    $r = InstalarComplemento $false
    if ($r.Hechos.Count) {
      Log "Complemento 'Cortes nube' instalado en: $($r.Hechos -join ', ')"
      [System.Windows.Forms.MessageBox]::Show("Se instalo el complemento 'Cortes nube' en $($r.Hechos -join ', ').`n`nCierra Revit (guarda tu trabajo) y vuelve a abrirlo.`nSi Revit pregunta por el complemento, elige 'Cargar siempre'.`n`nDesde entonces tus secciones apareceran solas en esta ventana.", 'Complemento de Revit', 'OK', 'Information') | Out-Null
    }
    foreach ($e in $r.Errores) { if ($e -like '(info)*') { Log $e.Substring(7) } else { Log "AVISO complemento: $e" } }
  } catch { Log "AVISO complemento: $($_.Exception.Message)" }
  CargarRevit
  $reloj.Start()
})
[void]$form.ShowDialog()
