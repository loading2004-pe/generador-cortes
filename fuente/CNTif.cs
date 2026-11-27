using System; using System.IO; using System.Collections.Generic;
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
