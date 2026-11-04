import sys, re, os

def norm(s):
    return re.sub(r'\s+', ' ', s.strip())

old_path, new_path = sys.argv[1], sys.argv[2]
exc_path = sys.argv[3] if len(sys.argv) > 3 else ""

old = open(old_path, encoding="utf-8", errors="replace").read().split("\n")
new = {norm(l) for l in open(new_path, encoding="utf-8", errors="replace").read().split("\n")}

exc = {}
if exc_path and os.path.exists(exc_path):
    for raw in open(exc_path, encoding="utf-8", errors="replace"):
        raw = raw.rstrip("\n")
        # marqueur de commentaire = ";;" et non "#", sinon un titre markdown
        # comme "## Prompt injection" serait pris pour un commentaire et l'exception
        # serait ignoree en silence (bug mesure le 2026-08-29)
        if not raw.strip() or raw.lstrip().startswith(";;"):
            continue
        line, _, why = raw.partition("\t")
        exc[norm(line)] = why.strip() or "(sans justification)"

lost = [l for l in old if l.strip() and norm(l) not in new]
excused = [l for l in lost if norm(l) in exc]
real = [l for l in lost if norm(l) not in exc]

if excused:
    print("EXCEPTIONS DOCUMENTEES (non reintegrees volontairement) :")
    for l in excused:
        print("  ~ %s" % l[:160])
        print("      motif : %s" % exc[norm(l)])
    print()
for l in real:
    print(l[:200])
sys.exit(1 if real else 0)
