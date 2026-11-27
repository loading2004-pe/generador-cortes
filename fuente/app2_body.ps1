
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
$VERSION_COMPLEMENTO = 'b57aed75a6'
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

        // resultado para el generador (sin ventanas en Revit: quedarian detras de la app y bloquearian Revit)
        static void ResultadoVinculo(bool ok, string msg)
        {
            try { File.WriteAllText(Path.Combine(Carpeta, "vincular_listo.txt"), (ok ? "OK|" : "ERROR|") + msg.Replace("\r", " ").Replace("\n", " ")); } catch (Exception) { }
        }

        public static void Vincular(Document doc, string ruta)
        {
            try
            {
                if (!File.Exists(ruta)) { ResultadoVinculo(false, "No existe la nube: " + ruta); return; }
                if (doc.IsFamilyDocument) { ResultadoVinculo(false, "Abre un PROYECTO de Revit (no una familia) para vincular la nube."); return; }
                string ext = Path.GetExtension(ruta).TrimStart('.').ToLowerInvariant();
                if (ext != "rcp" && ext != "rcs") { ResultadoVinculo(false, "La nube debe ser .rcp o .rcs: " + ruta); return; }
                using (Transaction t = new Transaction(doc, "Vincular nube (Cortes nube)"))
                {
                    t.Start();
                    PointCloudType tipo = PointCloudType.Create(doc, ext, ruta);
                    PointCloudInstance.Create(doc, tipo.Id, Transform.Identity);
                    t.Commit();
                }
                sucio = true;
                ResultadoVinculo(true, "Nube vinculada en " + doc.Title + " (origen a origen interno): " + Path.GetFileName(ruta));
            }
            catch (Exception ex) { Log(ex.ToString()); ResultadoVinculo(false, "No se pudo vincular la nube: " + ex.Message); }
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
                if (nube == "SIN NUBE VINCULADA") { inv = pc.GetTransform().Inverse; nube = pc.Name; }
                else nube += " + " + pc.Name;
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
    Get-ChildItem -LiteralPath $sub -Filter 'CortesNube.dll.viejo*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $enUso = $false
    try { Copy-Item $tmpDll $dll -Force }
    catch {
      # Revit abierto tiene la DLL tomada: Windows deja renombrarla; la nueva se usa al reiniciar Revit
      try { Rename-Item -LiteralPath $dll -NewName ('CortesNube.dll.viejo' + (Get-Date).Ticks); Copy-Item $tmpDll $dll -Force; $enUso = $true }
      catch { $errores += "Revit $($v.Anio): esta abierto. Cierralo y vuelve a abrir este programa para actualizar el complemento."; continue }
    }
    if ($enUso) { $script:reiniciarRevit = $true }
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
[CNWin]::AppId('QuintaHeeren.GeneradorCortes')
$form = New-Object System.Windows.Forms.Form
try { $exeIco = Get-ChildItem -LiteralPath $Root -Filter 'GeneradorCortes*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($exeIco) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exeIco.FullName) } } catch {}
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
$btnAyuda = Boton 'Guia / como hago un corte' 785 10 190 30
$lblGuia = Etiqueta 'Marca los cortes y pulsa GENERAR. El nombre es el de la seccion de Revit (doble clic para cambiarlo). Guia: boton de arriba a la derecha.' 15 42 960 22 $false
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
$miAsis = New-Object System.Windows.Forms.ToolStripMenuItem('Pedir un cambio / reportar un error al asistente...')
$miAsis.Add_Click({ PedirAsistente })
[void]$menuHerr.Items.Add($miAsis)
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
# registro en disco (lo lee el asistente para encontrar errores): <programa>\asistente\registro.log
$AsisDir = Join-Path $Root 'asistente'
try { New-Item -ItemType Directory -Force -Path $AsisDir | Out-Null } catch {}
$RegLog = Join-Path $AsisDir 'registro.log'
try { if ((Test-Path -LiteralPath $RegLog) -and (Get-Item -LiteralPath $RegLog).Length -gt 2MB) { Move-Item -LiteralPath $RegLog -Destination ($RegLog + '.1') -Force } } catch {}
function Log([string]$s) {
  $log.AppendText($s + "`r`n")
  $extra = @(foreach ($l in [CNLog]::Sacar()) { if ($l.Trim()) { '   ' + $l.Trim() } })
  foreach ($l in $extra) { $log.AppendText($l + "`r`n") }
  try { Add-Content -LiteralPath $RegLog -Value (@((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $s) + $extra) -Encoding UTF8 } catch {}
}
# pedir un cambio al asistente (lo revisa cada pocas horas, corrige, prueba y publica)
function PedirAsistente {
  $f = New-Object System.Windows.Forms.Form; $f.Text = 'Pedir un cambio al asistente'; $f.Size = New-Object System.Drawing.Size(620, 380)
  $f.StartPosition = 'CenterParent'; $f.Font = $fuente; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $l = New-Object System.Windows.Forms.Label; $l.Location = New-Object System.Drawing.Point(12, 10); $l.Size = New-Object System.Drawing.Size(580, 60)
  $l.Text = "Escribe con tus palabras que quieres cambiar, agregar o que error viste. El asistente lo revisa cada pocas horas, corrige el programa y publica una actualizacion. Los mensajes de esta ventana se le envian solos."
  $f.Controls.Add($l)
  $t = New-Object System.Windows.Forms.TextBox; $t.Multiline = $true; $t.ScrollBars = 'Vertical'; $t.Location = New-Object System.Drawing.Point(12, 75); $t.Size = New-Object System.Drawing.Size(580, 200); $f.Controls.Add($t)
  $u = New-Object System.Windows.Forms.CheckBox; $u.Text = 'Urgente (me impide trabajar)'; $u.Location = New-Object System.Drawing.Point(12, 290); $u.AutoSize = $true; $f.Controls.Add($u)
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Enviar'; $ok.Location = New-Object System.Drawing.Point(392, 290); $ok.Size = New-Object System.Drawing.Size(95, 32); $ok.DialogResult = 'OK'; $f.Controls.Add($ok)
  $ca = New-Object System.Windows.Forms.Button; $ca.Text = 'Cancelar'; $ca.Location = New-Object System.Drawing.Point(497, 290); $ca.Size = New-Object System.Drawing.Size(95, 32); $ca.DialogResult = 'Cancel'; $f.Controls.Add($ca)
  if ($f.ShowDialog($form) -ne 'OK' -or -not $t.Text.Trim()) { return }
  $item = [ordered]@{ id = (Get-Date -Format 'yyyyMMdd-HHmmss'); fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm'); app = 'Generador de cortes'; version = $env:CN_VERSION; urgente = [bool]$u.Checked; pedido = $t.Text.Trim(); estado = 'pendiente' }
  Add-Content -LiteralPath (Join-Path $AsisDir 'pedidos.jsonl') -Value (ConvertTo-Json $item -Compress) -Encoding UTF8
  Log "Pedido enviado al asistente: $($t.Text.Trim())"
  [System.Windows.Forms.MessageBox]::Show("Pedido enviado. Las respuestas del asistente quedan en:`n$(Join-Path $AsisDir 'respuestas.jsonl')`n(y se muestran al abrir el programa).", 'Asistente', 'OK', 'Information') | Out-Null
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
  $nom = LeerNombres; $usados = @{}; $idx = 0
  foreach ($p in $script:pares) { $n0 = $nom[$p.Clave]; if ($n0) { $usados[$n0.ToUpperInvariant()] = 1 } }
  foreach ($p in $script:pares) {
    $n = $nom[$p.Clave]
    if (-not $n) {
      # sin pedir nombres: se usa el nombre de la seccion de Revit (o una letra), sin repetir
      $base = [string]$p.Sugerido; if (-not $base) { $base = Letra $idx }
      $n = $base; $j = 2; while ($usados.ContainsKey($n.ToUpperInvariant())) { $n = "$base ($j)"; $j++ }
      $usados[$n.ToUpperInvariant()] = 1
    }
    $idx++
    $k = if ($p.Fondo) { $p.Fondo } else { $p.Rojo }
    $it = New-Object System.Windows.Forms.ListViewItem($n)
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
      catch {
        Log "Corte $L : 'Corte $L.dwg' esta abierto en AutoCAD. Cierralo y vuelve a intentar."
        [System.Windows.Forms.MessageBox]::Show("'Corte $L.dwg' esta abierto en AutoCAD.`n`nCierralo (guarda si lo cambiaste) y vuelve a generar ese corte.", 'Generador de cortes', 'OK', 'Warning') | Out-Null
        continue
      }
      # copia de seguridad del DWG anterior (por si lo habias retocado a mano)
      $ant = Join-Path $DwgDir 'anteriores'
      try { New-Item -ItemType Directory -Force -Path $ant | Out-Null; Copy-Item -LiteralPath $dwg -Destination (Join-Path $ant "Corte $L.dwg") -Force; Log "   (el DWG anterior se guardo en CORTES DWG\anteriores)" } catch {}
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
function DwgAbierto([string]$n) {
  $f = Join-Path $DwgDir "Corte $n.dwg"
  if (-not (Test-Path -LiteralPath $f)) { return $false }
  try { $fs = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None'); $fs.Close(); $false } catch { $true }
}
# pide a Revit que vincule la nube y espera la respuesta del complemento (vincular_listo.txt)
function VincularEnRevit([string]$ruta) {
  if (-not @(Get-Process -Name Revit -ErrorAction SilentlyContinue).Count) { [System.Windows.Forms.MessageBox]::Show('Abre Revit con tu proyecto y vuelve a intentarlo.', 'Vincular en Revit', 'OK', 'Warning') | Out-Null; return }
  $listo = Join-Path (Split-Path $PedidoVinc -Parent) 'vincular_listo.txt'
  New-Item -ItemType Directory -Force -Path (Split-Path $PedidoVinc -Parent) | Out-Null
  Remove-Item -LiteralPath $listo -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText($PedidoVinc, $ruta)
  Paso "Revit esta vinculando $([IO.Path]::GetFileName($ruta))..."
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt 90 -and -not (Test-Path -LiteralPath $listo)) { Start-Sleep -Milliseconds 300; [System.Windows.Forms.Application]::DoEvents() }
  if (-not (Test-Path -LiteralPath $listo)) {
    if (Test-Path -LiteralPath $PedidoVinc) { Remove-Item -LiteralPath $PedidoVinc -Force -ErrorAction SilentlyContinue; $m = 'Revit no respondio. Revisa que tu proyecto este abierto y que el complemento Cortes nube este cargado (si acabas de instalarlo, reinicia Revit).' }
    else { $m = 'Revit recibio el pedido. Revisa en Revit si la nube quedo vinculada.' }
    Paso $m; [System.Windows.Forms.MessageBox]::Show($m, 'Vincular en Revit', 'OK', 'Warning') | Out-Null; return
  }
  $r = (Get-Content -LiteralPath $listo -Raw).Trim(); Remove-Item -LiteralPath $listo -Force -ErrorAction SilentlyContinue
  $ok = $r -like 'OK|*'; $m = $r -replace '^(OK|ERROR)\|', ''
  Paso $m
  if (-not $ok) { [System.Windows.Forms.MessageBox]::Show($m, 'Vincular en Revit', 'OK', 'Warning') | Out-Null }
  else { Log '   (guarda el proyecto en Revit para que el vinculo quede)' }
}

# al terminar: abrir el DWG (un corte) o la carpeta CORTES DWG (varios)
function OfrecerAbrir([string[]]$hechos) {
  $hechos = @($hechos | Where-Object { $_ }); if (-not $hechos.Count) { return }
  if ($hechos.Count -eq 1) {
    $f = Join-Path $DwgDir "Corte $($hechos[0]).dwg"
    if ((Test-Path -LiteralPath $f) -and [System.Windows.Forms.MessageBox]::Show("Listo: Corte $($hechos[0]).dwg`n`nQuieres abrirlo ahora en AutoCAD?", 'Generador de cortes', 'YesNo', 'Question') -eq 'Yes') { Start-Process -FilePath $f }
  } elseif ([System.Windows.Forms.MessageBox]::Show("Listos $($hechos.Count) cortes en DWG.`n`nQuieres abrir la carpeta CORTES DWG?", 'Generador de cortes', 'YesNo', 'Question') -eq 'Yes') { Start-Process explorer.exe -ArgumentList ('"' + $DwgDir + '"') }
}
# acceso directo en el escritorio y en el menu Inicio (solo si se abrio desde GeneradorCortes.exe)
function CrearAccesos {
  if (-not $env:CN_LANZADOR) { return }
  $exe = Get-ChildItem -LiteralPath $Root -Filter 'GeneradorCortes*.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $exe) { return }
  $sh = New-Object -ComObject WScript.Shell; $nuevos = @()
  foreach ($c in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
    if (-not $c) { continue }
    $l = Join-Path $c 'Generador de cortes.lnk'
    try {
      if ((Test-Path -LiteralPath $l) -and ($sh.CreateShortcut($l).TargetPath -eq $exe.FullName)) { continue }
      $a = $sh.CreateShortcut($l); $a.TargetPath = $exe.FullName; $a.WorkingDirectory = $Root; $a.IconLocation = $exe.FullName + ',0'
      $a.Description = 'Generador de cortes: secciones de Revit + nube de puntos a DWG'; $a.Save(); $nuevos += $c
    } catch { Log "AVISO: no se pudo crear el acceso directo en $c ($($_.Exception.Message))" }
  }
  if ($nuevos.Count) { Log "Acceso directo 'Generador de cortes' creado en el escritorio y el menu Inicio." }
}
# guia de 3 pasos (la primera vez, y desde el boton de ayuda)
function MostrarGuia {
  [System.Windows.Forms.MessageBox]::Show(
    "COMO SE USA (3 pasos)`n`n" +
    "1. ABRE REVIT con tu proyecto y la nube vinculada.`n" +
    "    Esta ventana lo detecta sola: arriba veras 'Revit abierto - proyecto - nube - N cortes'.`n`n" +
    "2. HAZ TUS SECCIONES en Revit (Vista > Seccion). Aparecen solas en la lista.`n" +
    "    El nombre de cada corte es el de la seccion de Revit (doble clic para cambiarlo).`n`n" +
    "3. PULSA 'GENERAR CORTES'. El programa saca las imagenes de la nube (carpeta TIFF)`n" +
    "    y arma el DWG a escala real (carpeta CORTES DWG). Al terminar te ofrece abrirlo.`n`n" +
    "Si ya tienes los TIFF: boton 'Ya tengo los TIFF: pasar a AutoCAD'.`n`n" +
    "IMPORTANTE:`n" +
    " - No toques AutoCAD mientras arma el DWG (se abre y cierra solo).`n" +
    " - La primera vez, cierra y vuelve a abrir Revit para cargar el complemento ('Cargar siempre').`n" +
    " - Si arriba sale 'SIN NUBE VINCULADA', vincula la nube en Revit o usa Herramientas.",
    'Generador de cortes - guia rapida', 'OK', 'Information') | Out-Null
}

# nombre del corte y tipo de imagen segun el nombre del TIFF
#   Corte_<n>_revit_conjunto / _rojo (del generador), "<n> CCL" / "<n> LC" (exportados de Revit: con fondo / linea de corte)
function ClaseTiff([string]$f) {
  $b = [IO.Path]::GetFileNameWithoutExtension($f)
  if ($b -match '^Corte_(.+)_revit_(conjunto|rojo)$') { return @{ N = $Matches[1]; K = $Matches[2]; Otro = $(if ($Matches[2] -eq 'rojo') { "Corte_$($Matches[1])_revit_conjunto" } else { "Corte_$($Matches[1])_revit_rojo" }) } }
  if ($b -match '^(.+?)\s+(CCL|LC)$') { $n = ($Matches[1].Trim() -replace '^Corte[_ ]+', ''); $k = if ($Matches[2] -ieq 'LC') { 'rojo' } else { 'conjunto' }; $o = $b.Substring(0, $b.Length - $Matches[2].Length) + $(if ($k -eq 'rojo') { 'CCL' } else { 'LC' }); return @{ N = ($n -replace '[\\/:*?"<>|]', '_'); K = $k; Otro = $o } }
  return @{ N = (($b -replace '^Corte[_ ]', '') -replace '[\\/:*?"<>|]', '_'); K = 'conjunto'; Otro = $null }
}
# escala de TIFF que no la traen grabada (p. ej. exportados de Revit): ppp + escala con que se exportaron
function PedirEscala([int]$cuantos, [double]$pppTag) {
  $f = New-Object System.Windows.Forms.Form; $f.Text = 'Escala de los TIFF'; $f.Size = New-Object System.Drawing.Size(560, 300); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.Font = $fuente
  $l = New-Object System.Windows.Forms.Label; $l.Location = New-Object System.Drawing.Point(15, 12); $l.Size = New-Object System.Drawing.Size(520, 110)
  $l.Text = "$cuantos TIFF no traen su medida real grabada (no son del generador).`n`nIndica con que resolucion y a que escala los exportaste. En Revit la escala es la de la vista (sale en el titulo, p. ej. '1 : 100'); la resolucion es la elegida al exportar la imagen.`nSi te equivocas, el DWG sale mas grande o mas chico (p. ej. la mitad)."
  $f.Controls.Add($l)
  $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Resolucion (ppp):'; $l1.Location = New-Object System.Drawing.Point(15, 135); $l1.AutoSize = $true; $f.Controls.Add($l1)
  $c1 = New-Object System.Windows.Forms.ComboBox; $c1.DropDownStyle = 'DropDownList'; $c1.Location = New-Object System.Drawing.Point(160, 131); $c1.Size = New-Object System.Drawing.Size(90, 26)
  foreach ($v in '72', '96', '150', '200', '300', '400', '600', '1200') { [void]$c1.Items.Add($v) }
  $ini = if ($pppTag -gt 1) { [string][int][math]::Round($pppTag) } else { [string]$cmbPpp.SelectedItem }; if (-not $c1.Items.Contains($ini)) { [void]$c1.Items.Add($ini) }; $c1.SelectedItem = $ini; $f.Controls.Add($c1)
  $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'Escala   1 :'; $l2.Location = New-Object System.Drawing.Point(280, 135); $l2.AutoSize = $true; $f.Controls.Add($l2)
  $c2 = New-Object System.Windows.Forms.ComboBox; $c2.DropDownStyle = 'DropDownList'; $c2.Location = New-Object System.Drawing.Point(365, 131); $c2.Size = New-Object System.Drawing.Size(90, 26)
  foreach ($v in '10', '20', '25', '50', '75', '100', '125', '200', '250', '500') { [void]$c2.Items.Add($v) }
  $c2.SelectedItem = '100'; $f.Controls.Add($c2)
  $lp = New-Object System.Windows.Forms.Label; $lp.Location = New-Object System.Drawing.Point(15, 175); $lp.Size = New-Object System.Drawing.Size(520, 24); $lp.ForeColor = [System.Drawing.Color]::DarkSlateBlue; $f.Controls.Add($lp)
  $act = { $lp.Text = ('= cada pixel mide {0:N2} mm en la realidad' -f (25.4 / [double]$c1.SelectedItem * [double]$c2.SelectedItem)) }.GetNewClosure()
  $c1.Add_SelectedIndexChanged($act); $c2.Add_SelectedIndexChanged($act); & $act
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Aceptar'; $ok.Location = New-Object System.Drawing.Point(330, 212); $ok.Size = New-Object System.Drawing.Size(100, 32); $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
  $ca = New-Object System.Windows.Forms.Button; $ca.Text = 'Cancelar'; $ca.Location = New-Object System.Drawing.Point(440, 212); $ca.Size = New-Object System.Drawing.Size(95, 32); $ca.DialogResult = 'Cancel'; $f.Controls.Add($ca); $f.CancelButton = $ca
  if ($f.ShowDialog($form) -ne 'OK') { return $null }
  return @{ Ppp = [double]$c1.SelectedItem; Esc = [double]$c2.SelectedItem }
}

# Revit achica EN SILENCIO las imagenes que pasarian de ~15000 px (o se exportan con otro tamano, p. ej. la planta):
# se detecta comparando el alto de las letras del titulo de la vista (en papel siempre mide lo mismo) y, en una
# pareja CCL + LC, el ancho de la linea roja. A cada TIFF afectado se le da su propio tamano de pixel.
function CorregirRecortesRevit([string]$dir, [string[]]$nombres) {
  $px0 = [CNPrep]::PxSinGeo
  if ($px0 -le 0) { return }
  Paso 'Revisando si Revit achico alguna imagen...'
  $info = @{}
  foreach ($n in $nombres) {
    foreach ($k in 'conjunto', 'rojo') {
      $f = Join-Path $dir "Corte_$($n)_revit_$k.tif"
      if (Test-Path -LiteralPath $f) { $info["$n|$k"] = @{ F = $f; W = [CNPrep]::AnchoPx($f); T = -1.0; R = -1 } }
    }
  }
  $LIM = 14990
  # titulo de referencia: imagenes no recortadas que tienen titulo (con 3 basta)
  $refs = @()
  foreach ($kv in ($info.GetEnumerator() | Sort-Object Name)) {
    if ($refs.Count -ge 3) { break }
    $i = $kv.Value
    if ($i.W -lt $LIM -and $kv.Name -like '*|conjunto') { $i.T = [CNPrep]::AltoTitulo($i.F); if ($i.T -gt 0) { $refs += $i.T } }
  }
  if (-not $refs.Count) { Log '   (no hay titulo de Revit para comparar: se usa el mismo pixel para todas)'; return }
  $Tref = ($refs | Sort-Object)[[int][math]::Floor(($refs.Count - 1) / 2)]
  $cambios = @()
  foreach ($kv in $info.GetEnumerator()) {
    $n, $k = $kv.Name.Split('|'); $i = $kv.Value
    $otro = $info["$n|$(if ($k -eq 'rojo') { 'conjunto' } else { 'rojo' })"]
    $f = 1.0; $como = ''
    if ($i.W -ge $LIM -and $otro -and $otro.W -lt $LIM) {
      # recortada por Revit y su pareja no: la linea roja da la proporcion exacta
      if ($i.R -lt 0) { $i.R = [CNPrep]::AnchoRojo($i.F) }; if ($otro.R -lt 0) { $otro.R = [CNPrep]::AnchoRojo($otro.F) }
      if ($i.R -gt 100 -and $otro.R -gt 100) { $f = $i.R / $otro.R; $como = 'linea roja vs su pareja' }
    }
    if (-not $como -and $k -eq 'conjunto' -and ($i.W -ge $LIM -or -not $otro)) {
      if ($i.T -lt 0) { $i.T = [CNPrep]::AltoTitulo($i.F) }
      if ($i.T -gt 0) { $f = $i.T / $Tref; $como = 'tamano del titulo' }
    }
    if ($como -and [math]::Abs($f - 1) -gt 0.006 -and $f -gt 0.05) {
      $cambios += @{ F = $i.F; N = $n; K = $k; Fac = $f; Como = $como }
    }
  }
  if (-not $cambios.Count) { Log '   Ninguna: todas pasan tal cual.'; return }
  $txt = ($cambios | ForEach-Object { "   Corte {0} ({1}): Revit la exporto al {2:N1} %" -f $_.N, $(if ($_.K -eq 'rojo') { 'linea de corte' } else { 'con fondo' }), ($_.Fac * 100) }) -join "`n"
  $r = [System.Windows.Forms.MessageBox]::Show(
    "Revit achico estas imagenes al exportarlas (no deja pasar de 15000 px de ancho):`n`n$txt`n`n" +
    "Las imagenes NO se modifican en ningun caso (pasan pixel por pixel).`n`n" +
    "SI = compensar: esas imagenes ocupan en AutoCAD su tamano real (recomendado).`n" +
    "NO = pasar todo tal cual (esas quedaran mas chicas que el resto).",
    'Imagenes achicadas por Revit', 'YesNo', 'Question')
  foreach ($c in $cambios) {
    if ($r -eq 'Yes') {
      [CNPrep]::PxArchivo($c.F, $px0 / $c.Fac)
      Log ("   Corte {0} ({1}): compensado, pixel {2:N2} mm ({3})" -f $c.N, $(if ($c.K -eq 'rojo') { 'linea de corte' } else { 'con fondo' }), ($px0 / $c.Fac * 1000), $c.Como)
    } else {
      Log ("   Corte {0}: se pasa tal cual (Revit la achico al {1:N1} %)" -f $c.N, ($c.Fac * 100))
    }
  }
}

function TiffACad {
  if (-not $AUTOCAD) { throw 'No encuentro AutoCAD instalado.' }
  [CNPrep]::PxPorArchivo.Clear()
  $d = New-Object System.Windows.Forms.OpenFileDialog
  $d.Title = 'Elige los TIFF de tus cortes (puedes elegir varios)'; $d.Filter = 'Imagenes TIFF (*.tif;*.tiff)|*.tif;*.tiff'; $d.Multiselect = $true
  $memo = Join-Path $Tmp 'ultima_carpeta_tif.txt'
  if (-not $script:ultimaCarpetaTif -and (Test-Path -LiteralPath $memo)) { $script:ultimaCarpetaTif = (Get-Content -LiteralPath $memo -Raw).Trim() }
  if ($script:ultimaCarpetaTif -and (Test-Path -LiteralPath $script:ultimaCarpetaTif)) { $d.InitialDirectory = $script:ultimaCarpetaTif } elseif (Test-Path -LiteralPath $TifDir) { $d.InitialDirectory = $TifDir }
  if ($d.ShowDialog() -ne 'OK') { return }
  $carpeta = Split-Path $d.FileNames[0] -Parent; $script:ultimaCarpetaTif = $carpeta; try { Set-Content -LiteralPath $memo -Value $carpeta } catch {}
  $elegidos = @($d.FileNames)
  # por lotes: si eliges uno solo, ofrece pasar todos los TIFF de esa carpeta
  $todos = @(Get-ChildItem -LiteralPath $carpeta -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.tiff?$' } | Sort-Object Name | ForEach-Object { $_.FullName })
  if ($elegidos.Count -eq 1 -and $todos.Count -gt 2) {
    if ([System.Windows.Forms.MessageBox]::Show("En esa carpeta hay $($todos.Count) TIFF.`n`nPasarlos TODOS a AutoCAD?`n(No = solo el que elegiste y su pareja)", 'Ya tengo los TIFF', 'YesNo', 'Question') -eq 'Yes') { $elegidos = $todos }
  }
  $dir = Join-Path $Tmp 'tiff_a_autocad'
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  foreach ($x in $dir, $DwgDir, $Png) { New-Item -ItemType Directory -Force -Path $x | Out-Null }
  $nombres = @()
  # si eliges solo una de las dos imagenes de un corte, se agrega la otra (con fondo / linea de corte)
  $archivos = New-Object System.Collections.Generic.List[string]
  foreach ($f in $elegidos) {
    if (-not $archivos.Contains($f)) { $archivos.Add($f) }
    $c = ClaseTiff $f
    if ($c.Otro) { foreach ($ext in [IO.Path]::GetExtension($f), '.tif', '.tiff') { $otro = Join-Path (Split-Path $f -Parent) ($c.Otro + $ext); if ((Test-Path -LiteralPath $otro) -and -not $archivos.Contains($otro)) { $archivos.Add($otro); break } } }
  }
  # medida: los TIFF sin georreferencia necesitan ppp + escala
  $sinMedida = @(); $pppTag = 0
  foreach ($f in $archivos) { try { $m = [CNPrep]::Medida($f); if ($m -ne 0) { $sinMedida += $f; if ([CNPrep]::UltimosPpp -gt 1) { $pppTag = [CNPrep]::UltimosPpp } } } catch { Log "   (no se puede leer) $([IO.Path]::GetFileName($f)): $($_.Exception.Message)" } }
  [CNPrep]::SinGeo.Clear()
  if ($sinMedida.Count) {
    $e = PedirEscala $sinMedida.Count $pppTag
    if (-not $e) { Paso 'Cancelado.'; return }
    [CNPrep]::Escala = 0; [CNPrep]::PxSinGeo = 0.0254 / $e.Ppp * $e.Esc   # Escala 0: se usa este pixel para todos
    Log ("TIFF sin medida grabada: {0} ppp a 1:{1}  ->  pixel {2:N2} mm" -f $e.Ppp, $e.Esc, ([CNPrep]::PxSinGeo * 1000))
  }
  foreach ($f in $archivos) {
    $c = ClaseTiff $f; $n = $c.N; $k = $c.K
    $dst = Join-Path $dir "Corte_$($n)_revit_$k.tif"
    if (Test-Path -LiteralPath $dst) { Log "   (repetido, se ignora) $f"; continue }
    Copy-Item -LiteralPath $f -Destination $dst -Force
    if ($nombres -notcontains $n) { $nombres += $n }
  }
  if (-not $nombres.Count) { return }
  if ($sinMedida.Count) { CorregirRecortesRevit $dir $nombres }
  $abiertos = @($nombres | Where-Object { DwgAbierto $_ } | ForEach-Object { "Corte $_.dwg" })
  if ($abiertos.Count) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue; [System.Windows.Forms.MessageBox]::Show("Estos DWG estan abiertos en AutoCAD:`n`n   $($abiertos -join "`n   ")`n`nCierralos (guarda si los cambiaste) y vuelve a intentarlo.", 'Generador de cortes', 'OK', 'Warning') | Out-Null; return }
  $script:trabajando = $true
  foreach ($c in $btnGen, $btnTiff, $lista, $btnHerr) { $c.Enabled = $false }
  try {
    $barra.Maximum = $nombres.Count + 1; $barra.Value = 0
    Log "TIFF a AutoCAD: $($nombres.Count) corte(s): $($nombres -join ', ')"
    $ok = ArmarDwg $nombres $dir 0
    $barra.Value = $barra.Maximum
    Paso ("TERMINADO: {0} de {1} DWG en la carpeta CORTES DWG." -f $ok.Count, $nombres.Count)
    [System.Media.SystemSounds]::Asterisk.Play()
    $script:abrirLuego = $ok
  } catch { Log "ERROR: $($_.Exception.Message)"; Paso 'No se pudo terminar. Revisa los mensajes.' }
  finally {
    foreach ($c in $btnGen, $btnTiff, $lista, $btnHerr) { $c.Enabled = $true }
    $script:trabajando = $false
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:abrirLuego) { $x = $script:abrirLuego; $script:abrirLuego = $null; OfrecerAbrir $x }
}

# paso (m/pixel) que no pase el limite del motor (~1000 millones de pixeles por imagen)
function PasoSeguro($k, [double]$paso) {
  $area = [double]$k.Largo * [math]::Max(0.1, [double]($k.Zmax - $k.Zmin))
  $minimo = [math]::Sqrt($area / 9.0e8)
  if ($paso -lt $minimo) { [math]::Ceiling($minimo * 10000) / 10000 } else { $paso }
}

function Generar {
  $sel = @($lista.Items | Where-Object { $_.Checked })
  if ($sel.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Marca al menos un corte en la lista.', 'Generador de cortes') | Out-Null; return }
  if (-not $AUTOCAD) { throw 'No encuentro AutoCAD instalado.' }
  foreach ($d in $TifDir, $DwgDir, $Tmp, $Png) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  # antes de leer la nube: los DWG que se van a rehacer no pueden estar abiertos en AutoCAD
  $abiertos = @($sel | Where-Object { DwgAbierto $_.Text } | ForEach-Object { "Corte $($_.Text).dwg" })
  if ($abiertos.Count) { [System.Windows.Forms.MessageBox]::Show("Estos DWG estan abiertos en AutoCAD:`n`n   $($abiertos -join "`n   ")`n`nCierralos (guarda si los cambiaste) y vuelve a pulsar GENERAR.", 'Generador de cortes', 'OK', 'Warning') | Out-Null; return }
  # los nombres salen de Revit (doble clic en la lista para cambiarlos); se guardan para la proxima vez
  foreach ($it in $sel) { GuardarNombre $it.Tag.Clave $it.Text }
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
    $ped += [pscustomobject]@{ It = $it; Tipo = 'rojo'; Ruta = $rr }; $pr = PasoSeguro $p.Rojo $pasoRojo; $lin += [CNSec]::PedidoNube($p.Rojo, $p.Rojo.Dx, $p.Rojo.Dy, $pr, [math]::Max(0.004, 2 * $pr), $rr)
    if ($p.Fondo) {
      $rf = Join-Path $Tmp "raw_$($k)_fondo.tif"
      $ped += [pscustomobject]@{ It = $it; Tipo = 'fondo'; Ruta = $rf }; $pf = PasoSeguro $p.Fondo $px; if ($pf -gt $px) { Log "   $($it.Text): corte muy largo, el fondo se lee a $([math]::Round($pf*1000,1)) mm/pixel" }; $lin += [CNSec]::PedidoNube($p.Fondo, $p.Rojo.Dx, $p.Rojo.Dy, $pf, [math]::Max($RELLENO / 2, 2 * $pf), $rf)
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
  Paso ("TERMINADO: {0} DWG en la carpeta CORTES DWG." -f $hechos.Count)
  [System.Media.SystemSounds]::Asterisk.Play()
  OfrecerAbrir $hechos
}

# ============================== EVENTOS ==============================
$btnAyuda.Add_Click({
  MostrarGuia
  [System.Windows.Forms.MessageBox]::Show(
    "COMO HACER UN CORTE EN REVIT`n`n" +
    "1. En la planta donde se ve la nube: Vista > Seccion. Clic en el inicio y en el final del corte.`n" +
    "2. En sus Propiedades pon 'Desfase de delimitacion lejano' corto (p. ej. 0.10 m):`n" +
    "   esta seccion es la LINEA DE CORTE (si quieres, pinta la nube de rojo en esa vista).`n" +
    "3. Haz OTRA seccion sobre la MISMA linea (copia la primera) y ponle un desfase lejano grande`n" +
    "   (hasta el fondo que quieras ver): esta es la vista CON FONDO.`n" +
    "4. Las dos secciones aparecen solas en esta ventana como UN corte.`n" +
    "5. Pulsa GENERAR CORTES: usa el nombre de la seccion y hace el DWG a escala real.`n`n" +
    "Si solo haces una seccion larga, la linea de corte se saca sola con 10 cm.`n" +
    "La flecha de la seccion manda: la vista mira hacia donde mira la seccion en Revit.", 'Como hago un corte?', 'OK', 'Information') | Out-Null
})
$lista.Add_DoubleClick({
  if ($script:trabajando -or -not $lista.SelectedItems.Count) { return }
  $it = $lista.SelectedItems[0]; $p = $it.Tag
  $it.Checked = -not $it.Checked   # el doble clic de la lista cambia la marca: se deja como estaba
  $n = PedirNombre $p $it.Text
  if ($n -and @($lista.Items | Where-Object { $_ -ne $it -and $_.Text -ieq $n }).Count) { [System.Windows.Forms.MessageBox]::Show("Ya hay otro corte llamado '$n'. Elige otro nombre.", 'Nombre del corte', 'OK', 'Warning') | Out-Null; return }
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
      VincularEnRevit $rcp.FullName
    }
  } finally { $btnLas.Enabled = $true; $btnGen.Enabled = $true }
})
$btnVinc.Add_Click({
  $d = New-Object System.Windows.Forms.OpenFileDialog
  $d.Title = 'Elige la nube indexada (.rcp o .rcs) para vincular en Revit'
  $d.Filter = 'Nube de ReCap (*.rcp;*.rcs)|*.rcp;*.rcs'
  if ($NUBE) { $d.InitialDirectory = Split-Path $NUBE -Parent }
  if ($d.ShowDialog() -ne 'OK') { return }
  VincularEnRevit $d.FileName
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
  try {
    $rf = Join-Path $AsisDir 'respuestas.jsonl'; $vf = Join-Path $AsisDir 'respuestas_vistas.txt'
    if (Test-Path -LiteralPath $rf) {
      $vistas = 0; if (Test-Path -LiteralPath $vf) { $vistas = [int](Get-Content -LiteralPath $vf -Raw) }
      $rs = @(Get-Content -LiteralPath $rf -Encoding UTF8 | Where-Object { $_.Trim() })
      for ($i = $vistas; $i -lt $rs.Count; $i++) { $r = $rs[$i] | ConvertFrom-Json; Log "Asistente ($($r.fecha)): $($r.estado) - $($r.respuesta)" }
      Set-Content -LiteralPath $vf -Value $rs.Count
    }
  } catch {}
  Log "Carpetas de salida (junto al programa):  TIFF -> $TifDir   |   CORTES DWG -> $DwgDir"
  Log ("Revit en esta PC: " + (($script:revits | ForEach-Object { if ($_.Anio -ge $REVIT_MINIMO) { "Revit $($_.Anio) (ok)" } else { "Revit $($_.Anio) (muy antiguo, se ignora)" } }) -join ', '))
  [System.Windows.Forms.Application]::DoEvents()
  try {
    $r = InstalarComplemento $false
    if ($r.Hechos.Count) {
      Log "Complemento 'Cortes nube' instalado en: $($r.Hechos -join ', ')"
      if ($script:reiniciarRevit) { Log "   Hay una mejora del complemento: se usara la proxima vez que abras Revit (puedes seguir trabajando)." }
      else { [System.Windows.Forms.MessageBox]::Show("Se instalo el complemento 'Cortes nube' en $($r.Hechos -join ', ').`n`nCierra Revit (guarda tu trabajo) y vuelve a abrirlo.`nSi Revit pregunta por el complemento, elige 'Cargar siempre'.`n`nDesde entonces tus secciones apareceran solas en esta ventana.", 'Complemento de Revit', 'OK', 'Information') | Out-Null }
    }
    foreach ($e in $r.Errores) { if ($e -like '(info)*') { Log $e.Substring(7) } else { Log "AVISO complemento: $e" } }
  } catch { Log "AVISO complemento: $($_.Exception.Message)" }
  try { CrearAccesos } catch { Log "AVISO acceso directo: $($_.Exception.Message)" }
  CargarRevit
  $guia = Join-Path $Tmp 'guia_vista.txt'
  if (-not (Test-Path -LiteralPath $guia)) { MostrarGuia; try { New-Item -ItemType Directory -Force -Path $Tmp | Out-Null; Set-Content -LiteralPath $guia -Value (Get-Date) } catch {} }
  $reloj.Start()
})
[void]$form.ShowDialog()
