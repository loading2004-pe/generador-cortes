"""Publica una version nueva del Generador de cortes (la reciben todas las PC al abrir la app).

    python publicar.py [--notas "que cambio"] [--min-lanzador N]

Sube la version (fecha.N), escribe version.json con el sha256 de GENERADOR_DE_CORTES.bat y
LEEME_CORTES_REVIT.txt, y si la carpeta es un repositorio git hace commit y push.
"""
import argparse, hashlib, json, os, subprocess, time

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["GENERADOR_DE_CORTES.bat", "LEEME_CORTES_REVIT.txt"]

def k(v):
    return tuple(int(p) if p.isdigit() else 0 for p in str(v).split("."))

def siguiente(cur):
    cand = time.strftime("%Y.%m.%d") + ".1"
    if k(cand) > k(cur):
        return cand
    head, n = cur.rsplit(".", 1)
    return f"{head}.{int(n) + 1}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--notas", default="")
    ap.add_argument("--min-lanzador", type=int, default=1)
    a = ap.parse_args()
    try:
        cur = json.load(open(os.path.join(HERE, "version.json"), encoding="utf-8"))["version"]
    except Exception:
        cur = "0"
    ver = siguiente(cur)
    man = {"version": ver, "fecha": time.strftime("%Y-%m-%d %H:%M"), "notas": a.notas,
           "min_lanzador": a.min_lanzador, "archivos": {}}
    for fn in FILES:
        man["archivos"][fn] = hashlib.sha256(open(os.path.join(HERE, fn), "rb").read()).hexdigest()
    with open(os.path.join(HERE, "version.json"), "w", encoding="utf-8", newline="\r\n") as f:
        json.dump(man, f, indent=1, ensure_ascii=False)
    print("Version", ver)
    if os.path.isdir(os.path.join(HERE, ".git")):
        for cmd in (["git", "add", "-A"], ["git", "commit", "-m", f"Version {ver}: {a.notas}"], ["git", "push"]):
            subprocess.run(cmd, cwd=HERE, check=False)

if __name__ == "__main__":
    main()
