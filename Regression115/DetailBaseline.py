"""Compile the actual build-70 production parser alongside current sources."""
import pathlib, subprocess, re
root=pathlib.Path('/tmp/detail-baseline70');root.mkdir(exist_ok=True)
for name in ['HTML','DiscuzParser']:
 text=subprocess.check_output(['git','show','c1275bca1f69fba25d1c3c76c11709e969735989:SeHuaTang/Parser/'+name+'.swift'],text=True)
 for symbol in ['ThreadRequestGate','DiscuzParser','HTML']:
  text=re.sub(r'\b'+symbol+r'\b','Baseline'+symbol,text)
 (root/(name+'.swift')).write_text(text)
print('Prepared exact build-70 production parser comparison (symbols isolated, no logic rewriting)')
