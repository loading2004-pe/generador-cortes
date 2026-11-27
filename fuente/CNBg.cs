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
