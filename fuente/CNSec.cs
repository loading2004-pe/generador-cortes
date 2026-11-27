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
