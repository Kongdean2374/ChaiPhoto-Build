from pathlib import Path
import re,json,plistlib
ROOT=Path(__file__).resolve().parents[1]
def balanced(s,i):
 depth=1;start=i
 while i<len(s):
  if s[i]=='"': _,i=literal(s,i);continue
  if s[i]=='(':depth+=1
  if s[i]==')':
   depth-=1
   if depth==0:return s[start:i],i+1
  i+=1
 raise ValueError('unclosed interpolation')
def literal(s,i):
 assert s[i]=='"';i+=1;parts=[];buf=''
 while i<len(s):
  if s.startswith('\\(',i):
   parts.append(buf);buf='';expr,i=balanced(s,i+2);parts.append({'expr':expr});continue
  if s[i]=='\\':
   buf+= {'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\'}.get(s[i+1],s[i+1]);i+=2;continue
  if s[i]=='"':parts.append(buf);return parts,i+1
  buf+=s[i];i+=1
 raise ValueError('unclosed literal')
def fmt(parts, types=None):
 out='';ex=[]
 for p in parts:
  if isinstance(p,str):out+=p.replace('%','%%')
  else:
   expr=p['expr'];ex.append(expr)
   numeric=bool(re.search(r'\.count$|^(page \+ 1|value|summary\.1)$|\.(currentBuild|latestBuild)$|^currentBuild$',expr))
   out+='%lld' if numeric else '%@'
 return out,ex

def load_strings(path):
    result = {}
    pair = re.compile(r'^("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");$')
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith('//'): continue
        match = pair.fullmatch(line)
        if not match: raise ValueError("Invalid native strings entry: " + str(path))
        key, value = map(json.loads, match.groups())
        if key in result: raise ValueError("Duplicate key: " + str(path))
        result[key] = value
    return result

def inventory(root):
    entries = set()
    for path in (root / 'ChaiPhoto').glob('*.swift'):
        source = path.read_text()
        for match in re.finditer(r'\bL\(\s*(?=")', source):
            zh, end = literal(source, match.end())
            while source[end].isspace(): end += 1
            if source[end] != ',': raise ValueError("Nonliteral localization pair: " + str(path))
            end += 1
            while source[end].isspace(): end += 1
            en, end = literal(source, end)
            while source[end].isspace(): end += 1
            if source[end] != ')': raise ValueError("Dynamic key concatenation: " + str(path))
            english, _ = fmt(en)
            chinese, _ = fmt(zh)
            entries.add(english + ' || ' + chinese)
    return entries

def verify(root=ROOT):
    root = Path(root)
    expected = inventory(root)
    locales = ['zh-Hant','zh-Hans','en','ja','es','fr']
    for code in locales:
        folder = root / 'ChaiPhoto' / 'Localization' / (code + '.lproj')
        strings = load_strings(folder / 'Localizable.strings')
        plurals = plistlib.loads((folder / 'Localizable.stringsdict').read_bytes())
        if set(strings) & set(plurals): raise ValueError('String/plural duplicate: ' + code)
        if set(strings) | set(plurals) != expected:
            raise ValueError('Resource coverage mismatch: ' + code + repr(expected ^ (set(strings)|set(plurals))))
        for key in expected:
            english = key.split(' || ')[0]
            tokens = re.findall(r'%(?:lld|@)', english)
            values = [strings[key]] if key in strings else [plurals[key]['count'][rule] for rule in ['one','other']]
            for value in values:
                if not value.strip() or re.findall(r'%(?:lld|@)', value) != tokens:
                    raise ValueError('Missing text or wrong format arguments: ' + code + ' ' + key)
                if ' || ' in value: raise ValueError('Leaked resource key: ' + code)
        info = load_strings(folder / 'InfoPlist.strings')
        if not info.get('NSPhotoLibraryUsageDescription'): raise ValueError('Missing Photos purpose: ' + code)
    print(f'Native localization coverage verified: {len(expected)} messages x {len(locales)} languages; format arguments and plural variants intact')
    return len(expected)

if __name__ == '__main__': verify()
