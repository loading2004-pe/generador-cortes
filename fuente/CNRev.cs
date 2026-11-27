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
