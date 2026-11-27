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
