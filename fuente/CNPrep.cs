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
    // como sabe la medida del ultimo TIFF leido: 0 = georreferenciado, 1 = por sus ppp (+ escala), 2 = sin datos (pixel elegido)
    public static int UltimaMedida = 0; public static double UltimosPpp = 0;
    // pixel propio de cada TIFF sin georreferencia (Revit achica en silencio las imagenes de mas de 15000 px)
    public static Dictionary<string, double> PxPorArchivo = new Dictionary<string, double>();
    public static void PxArchivo(string path, double px) { PxPorArchivo[System.IO.Path.GetFullPath(path).ToLowerInvariant()] = px; }

    // Alto (px) de las letras del titulo de la vista de Revit (esquina inferior izquierda: "1  CORTE 5 / 1 : 100").
    // En papel siempre mide lo mismo: si una imagen lo tiene mas chico, Revit la achico. 0 = no hay titulo.
    public static double AltoTitulo(string path)
    {
        Tif t = ReadInfoRaw(path);
        int W = Math.Min(t.W, 4000), y0 = (int)(t.H * 0.75), H = t.H - y0;
        if (H < 20) return 0;
        bool[] m = new bool[W * H];
        byte[] row = new byte[t.W * 4];
        using (RowReader rr = new RowReader(t))
            for (int y = 0; y < H; y++)
            {
                rr.ReadRow(y0 + y, row);
                for (int x = 0; x < W; x++)
                {
                    int o = 4 * x;
                    if (row[o] < 140 && row[o + 1] < 140 && row[o + 2] < 140) m[y * W + x] = true;   // (negro puro incluido)
                }
                // fuera los tramos horizontales largos (subrayado del titulo, lineas): no son letras
                int run = 0;
                for (int x = 0; x <= W; x++)
                {
                    if (x < W && m[y * W + x]) { run++; continue; }
                    if (run > 300) for (int k = x - run; k < x; k++) m[y * W + k] = false;
                    run = 0;
                }
            }
        // componentes conexas (letras): alto y ancho de cada una
        int[] stack = new int[W * H];
        List<int> altos = new List<int>();
        for (int i = 0; i < m.Length; i++)
        {
            if (!m[i]) continue;
            int sp = 0; stack[sp++] = i; m[i] = false;
            int minx = int.MaxValue, maxx = -1, miny = int.MaxValue, maxy = -1, n = 0;
            while (sp > 0)
            {
                int k = stack[--sp]; int x = k % W, y = k / W; n++;
                if (x < minx) minx = x; if (x > maxx) maxx = x; if (y < miny) miny = y; if (y > maxy) maxy = y;
                if (x > 0 && m[k - 1]) { m[k - 1] = false; stack[sp++] = k - 1; }
                if (x < W - 1 && m[k + 1]) { m[k + 1] = false; stack[sp++] = k + 1; }
                if (y > 0 && m[k - W]) { m[k - W] = false; stack[sp++] = k - W; }
                if (y < H - 1 && m[k + W]) { m[k + W] = false; stack[sp++] = k + W; }
            }
            int h = maxy - miny + 1, w = maxx - minx + 1;
            if (h >= 20 && h <= 400 && w <= 1.6 * h && w >= 0.15 * h) altos.Add(h);
        }
        if (altos.Count < 4) return 0;
        altos.Sort();
        // letras mayusculas del titulo: mediana de las 6 mas altas (descarta el circulo y ruido)
        int c = altos.Count, k6 = Math.Min(6, c);
        return 0.5 * (altos[c - k6 + (k6 - 1) / 2] + altos[c - k6 + k6 / 2]);
    }

    // Ancho (px) de la linea de corte roja (para comparar un "CCL" con su "LC"). 0 = sin rojo.
    public static int AnchoRojo(string path)
    {
        Tif t = ReadInfoRaw(path);
        byte[] row = new byte[t.W * 4];
        int x0 = int.MaxValue, x1 = -1;
        using (RowReader rr = new RowReader(t))
            for (int y = 0; y < t.H; y++)
            {
                rr.ReadRow(y, row);
                for (int x = 0; x < t.W; x++)
                {
                    int o = 4 * x;
                    if (row[o] > 180 && row[o + 1] < 80 && row[o + 2] < 80) { if (x < x0) x0 = x; if (x > x1) x1 = x; }
                }
            }
        return x1 >= x0 ? x1 - x0 : 0;
    }
    public static int AnchoPx(string path) { return ReadInfoRaw(path).W; }
    public static int Medida(string path)
    {
        double e = Escala, p = PxSinGeo;
        try { Escala = 50; PxSinGeo = 0.001; ReadInfo(path); return UltimaMedida; } finally { Escala = e; PxSinGeo = p; }
    }
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

    // lee la cabecera sin exigir escala (para medir la imagen)
    static Tif ReadInfoRaw(string path)
    {
        double e = Escala, p = PxSinGeo; int n = SinGeo.Count;
        try { Escala = 0; PxSinGeo = 0.001; return ReadInfo(path); }
        finally { Escala = e; PxSinGeo = p; while (SinGeo.Count > n) SinGeo.RemoveAt(SinGeo.Count - 1); }
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
        UltimaMedida = 0; UltimosPpp = 0;
        if (!t.Geo || t.Sx <= 0)
        {
            UltimosPpp = t.Dpi > 1 ? (t.ResUnit == 3 ? t.Dpi * 2.54 : t.Dpi) : 0;
            UltimaMedida = UltimosPpp > 1 ? 1 : 2;
            double dpi = t.Dpi > 1 ? (t.ResUnit == 3 ? t.Dpi * 2.54 : t.Dpi) : 0;
            double px = (dpi > 1 && Escala > 0) ? 0.0254 / dpi * Escala : PxSinGeo;
            double pxArch;
            if (PxPorArchivo.TryGetValue(System.IO.Path.GetFullPath(path).ToLowerInvariant(), out pxArch) && pxArch > 0) px = pxArch;
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
    static bool Lleno(byte[] row, int x, bool blanco)
    {
        int o = 4 * x;
        if (row[o + 3] == 0) return false;
        return !(blanco && row[o] >= 245 && row[o + 1] >= 245 && row[o + 2] >= 245);
    }
    public static Tile[] Prepare(string src, string outDir, string baseName, double pixelFinal, int maxPx)
    {
        Tif t = ReadInfo(src);
        byte[] row = new byte[t.W * 4];
        bool blanco = t.Spp - t.Extra < 4 && t.Extra == 0;   // RGB sin transparencia (p. ej. exportado de Revit): el blanco es vacio
        int x0 = int.MaxValue, x1 = -1, y0 = int.MaxValue, y1 = -1;
        using (RowReader rr = new RowReader(t))
        {
            for (int y = 0; y < t.H; y++)
            {
                rr.ReadRow(y, row);
                int a = -1, b = -1;
                for (int x = 0; x < t.W; x++) if (Lleno(row, x, blanco)) { a = x; break; }
                if (a < 0) continue;
                for (int x = t.W - 1; x >= a; x--) if (Lleno(row, x, blanco)) { b = x; break; }
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
        string key = fi.Length + "|" + fi.LastWriteTimeUtc.Ticks + "|" + px.ToString("R", CultureInfo.InvariantCulture) + "|" + maxPx + "|v2|" + Escala.ToString("R", CultureInfo.InvariantCulture) + "|" + PxSinGeo.ToString("R", CultureInfo.InvariantCulture)
            + "|" + (PxPorArchivo.ContainsKey(System.IO.Path.GetFullPath(im.Path).ToLowerInvariant()) ? PxPorArchivo[System.IO.Path.GetFullPath(im.Path).ToLowerInvariant()].ToString("R", CultureInfo.InvariantCulture) : "-");
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
            M.Add("Y = 0 es el nivel +/-0.00 (Z = 0 de la nube) de la fila 'sin fondo'; la otra fila esta debajo (al menos " + F4(baja) + " m, mas si las imagenes son altas).");
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
                // la fila de abajo no debe pisar la de arriba (imagenes altas, p. ej. exportadas de Revit)
                double bj = baja;
                if (fr.Count > 0 && fo.Count > 0)
                {
                    double zminArr = double.MaxValue, zmaxAba = double.MinValue;
                    foreach (Tile t in fr) zminArr = Math.Min(zminArr, t.Zbot);
                    foreach (Tile t in fo) zmaxAba = Math.Max(zmaxAba, t.Zbot + t.H);
                    bj = Math.Max(baja, Math.Ceiling(zmaxAba - zminArr + 2.5));
                }
                foreach (Tile t in fr)
                {
                    S.Add("(cn:mete (cn:ole \"" + Lsp(t.File) + "\" " + F4(t.U + d) + " " + F4(t.Zbot) + " " + F4(t.W) + " " + F4(t.H) + " \"" + capaArr + "\") (quote cn:g1))");
                    M.Add(string.Format("{0,-44} {1,-16} {2,10} {3,10} {4,9} {5,9}", Path.GetFileName(t.File), capaArr, F4(t.U + d), F4(t.Zbot), F4(t.W), F4(t.H)));
                }
                foreach (Tile t in fo)
                {
                    S.Add("(cn:mete (cn:ole \"" + Lsp(t.File) + "\" " + F4(t.U + d) + " " + F4(t.Zbot - bj) + " " + F4(t.W) + " " + F4(t.H) + " \"" + capaAba + "\") (quote cn:g2))");
                    M.Add(string.Format("{0,-44} {1,-16} {2,10} {3,10} {4,9} {5,9}", Path.GetFileName(t.File), capaAba, F4(t.U + d), F4(t.Zbot - bj), F4(t.W), F4(t.H)));
                }
                double xa = x0, xb = umax + d;
                string lado = v == "ladoA" ? "mirando como la seccion de Revit" : v == "ladoB" ? "mirando al lado contrario" : v.Replace("mira", "hacia ");
                foreach (double yy in new double[] { 0.0, -bj })
                {
                    string gq = ")";
                    S.Add("(progn (cn:lin " + F4(xa - 0.5) + " " + F4(yy) + " " + F4(xb + 0.5) + " " + F4(yy) + " \"CORTE_NIVEL\")" + gq);
                    S.Add("(progn (cn:txt \"N. +/-0.00\" " + F4(xa - 0.5) + " " + F4(yy + 0.05) + " 0.15 \"CORTE_NIVEL\")" + gq);
                }
                if (v == "revit")
                {
                    S.Add("(progn (cn:txt \"corte " + L + " - con fondo y linea de corte\" " + F4(xa) + " -1.2 0.4 \"CORTE_TEXTO\"))");
                    S.Add("(progn (cn:txt \"corte " + L + " - seccion (linea de corte)\" " + F4(xa) + " " + F4(-1.2 - bj) + " 0.4 \"CORTE_TEXTO\"))");
                }
                else
                {
                    S.Add("(cn:txt \"corte " + L + " - sin fondo (franja de 10cm)  (" + lado + ")\" " + F4(xa) + " -1.2 0.4 \"CORTE_TEXTO\")");
                    S.Add("(cn:txt \"corte " + L + " - con fondo  (" + lado + ")\" " + F4(xa) + " " + F4(-1.2 - bj) + " 0.4 \"CORTE_TEXTO\")");
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

// ventana propia en la barra de tareas (si no, se agrupa con PowerShell y no se encuentra)
public static class CNWin
{
    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    public static void AppId(string id) { try { SetCurrentProcessExplicitAppUserModelID(id); } catch (Exception) { } }
}
