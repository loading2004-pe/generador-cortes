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
