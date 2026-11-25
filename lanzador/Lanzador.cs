// Generador de cortes - lanzador (.exe)
// Prepara su carpeta de datos (%LOCALAPPDATA%\GeneradorCortes), deja ahi el arranque y la copia del
// programa que trae incluida, y abre el arranque con PowerShell (sin consola). El arranque busca
// actualizaciones en GitHub, las descarga si el usuario acepta, y abre la version mas nueva.
// Las carpetas de trabajo (TIFF, CORTES DWG, _temp) se crean junto a este .exe.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("Generador de cortes")]
[assembly: AssemblyProduct("Generador de cortes - Quinta Heeren")]
[assembly: AssemblyDescription("Secciones de Revit + nube de puntos a AutoCAD")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Lanzador
{
    public const int VERSION_LANZADOR = 1;
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr h, string texto, string titulo, uint tipo);

    static void Sacar(string recurso, string destino)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(recurso))
        {
            if (s == null) throw new Exception("falta el recurso " + recurso);
            string tmp = destino + ".tmp";
            using (FileStream f = File.Create(tmp)) s.CopyTo(f);
            if (File.Exists(destino)) File.Delete(destino);
            File.Move(tmp, destino);
        }
    }

    [STAThread]
    static int Main(string[] args)
    {
        string raiz = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(new char[] { '\\' });
        // datos de la app: carpeta _app junto al .exe (si se puede escribir); si no, %LOCALAPPDATA%\GeneradorCortes
        string datos = Path.Combine(raiz, "_app");
        try { Directory.CreateDirectory(datos); string t = Path.Combine(datos, ".prueba"); File.WriteAllText(t, ""); File.Delete(t); }
        catch { datos = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GeneradorCortes"); }
        try
        {
            Directory.CreateDirectory(datos);
            string incluido = Path.Combine(datos, "incluido");
            Directory.CreateDirectory(incluido);
            Sacar("arranque.ps1", Path.Combine(datos, "arranque.ps1"));
            Sacar("GENERADOR_DE_CORTES.bat", Path.Combine(incluido, "GENERADOR_DE_CORTES.bat"));
            Sacar("version.json", Path.Combine(incluido, "version.json"));

            ProcessStartInfo p = new ProcessStartInfo();
            p.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(p.FileName)) p.FileName = "powershell.exe";
            string extra = Array.IndexOf(args, "--sin-actualizar") >= 0 ? " -SinActualizar" : "";
            string ps1 = Path.Combine(datos, "arranque.ps1").Replace("'", "''");
            string log = Path.Combine(datos, "arranque_error.txt").Replace("'", "''");
            p.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command \"try { & '" + ps1 + "'" + extra +
                " } catch { $m = $_ | Out-String; try { Set-Content -LiteralPath '" + log + "' -Value $m } catch {}; Add-Type -AssemblyName System.Windows.Forms; " +
                "[void][System.Windows.Forms.MessageBox]::Show('No se pudo abrir el Generador de cortes:' + [char]10 + [char]10 + $m, 'Generador de cortes') }\"";
            p.UseShellExecute = false;
            p.CreateNoWindow = true;
            p.WorkingDirectory = raiz;
            p.EnvironmentVariables["CN_ROOT"] = raiz + "\\";
            p.EnvironmentVariables["CN_DATA"] = datos;
            p.EnvironmentVariables["CN_LANZADOR"] = VERSION_LANZADOR.ToString();
            Process.Start(p);
            return 0;
        }
        catch (Exception ex)
        {
            try { File.AppendAllText(Path.Combine(datos, "lanzador_error.txt"), DateTime.Now + "  " + ex + Environment.NewLine); } catch { }
            try { MessageBoxW(IntPtr.Zero, "No se pudo abrir el Generador de cortes:\n\n" + ex.Message, "Generador de cortes", 0x10); } catch { }
            return 1;
        }
    }
}
