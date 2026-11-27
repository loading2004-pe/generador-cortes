#!/bin/bash
# Arma ../GENERADOR_DE_CORTES.bat = app2_head.ps1 + C# (CNPrep + CNTif + CNRev + CNBg + CNSec) + app2_body.ps1,
# con el complemento de Revit (addin/CortesNube.cs) y el motor (addin/CortesNubeMotor.cs) incrustados.
# Requiere mono (mcs) para comprobar que el C# compila. Uso:  bash fuente/build.sh
set -e
F="$(cd "$(dirname "$0")" && pwd)"
R="$(dirname "$F")"
T="$(mktemp -d)"
(for f in CNTif.cs CNRev.cs CNBg.cs CNSec.cs; do grep -v '^using ' "$F/$f"; done) > "$T/rest.cs"
(cat "$F/CNPrep.cs"; cat "$T/rest.cs") > "$T/all4.cs"
ERR=0
for spec in "all4:$T/all4.cs:-r:System.IO.Compression.dll" "cn:$F/addin/CortesNube.cs $F/addin/stub.cs:" "cnm:$F/addin/CortesNubeMotor.cs $F/addin/stub.cs:"; do
  n="${spec%%:*}"; rest="${spec#*:}"; srcs="${rest%%:*}"; extra="${rest#*:}"
  if ! mcs -target:library $extra -out:"$T/$n.dll" $srcs 2>"$T/$n.log"; then grep -v warning "$T/$n.log"; ERR=1; fi
done
[ $ERR = 0 ] || { echo "ERROR: el C# no compila; no se arma el .bat"; exit 1; }
python3 - "$F" <<'PY'
import hashlib,re,sys,os
F=sys.argv[1]; p=os.path.join(F,'app2_body.ps1'); s=open(p,encoding='utf-8').read()
def blk(var, path, verVar):
    global s
    src=open(path,encoding='utf-8').read()
    h=hashlib.md5(src.encode()).hexdigest()[:10]
    pat=re.compile(r"\$"+verVar+r" = '[^']*'\n\$"+var+r" = @'\n.*?\n'@\n", re.S)
    rep="$"+verVar+" = '"+h+"'\n$"+var+" = @'\n"+src.rstrip('\n')+"\n'@\n"
    if pat.search(s): s=pat.sub(lambda m: rep, s, count=1)
    else:
        i=s.index('$VERSION_COMPLEMENTO'); s=s[:i]+rep+s[i:]
blk('FUENTE_COMPLEMENTO',os.path.join(F,'addin','CortesNube.cs'),'VERSION_COMPLEMENTO')
blk('FUENTE_MOTOR',os.path.join(F,'addin','CortesNubeMotor.cs'),'VERSION_MOTOR')
open(p,'w',encoding='utf-8').write(s)
PY
(cat "$F/app2_head.ps1" "$T/all4.cs" "$F/app2_body.ps1") | sed 's/\r$//' > "$T/n.txt"
L=$(grep -n "^'@$" "$T/n.txt" | head -1 | cut -d: -f1)
sed "$((L-1))d" "$T/n.txt" | sed 's/$/\r/' > "$R/GENERADOR_DE_CORTES.bat"
if LC_ALL=C grep -q -P '[^\x00-\x7F]' "$R/GENERADOR_DE_CORTES.bat"; then echo "AVISO: hay caracteres no ASCII (PowerShell 5 los lee mal)"; fi
rm -rf "$T"
ls -l "$R/GENERADOR_DE_CORTES.bat"
