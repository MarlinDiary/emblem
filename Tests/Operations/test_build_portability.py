import re,subprocess,unittest
from pathlib import Path
class BuildShellTests(unittest.TestCase):
 def testAdhocOptionsAreDefinedWithBashNounset(self):
  s=(Path(__file__).resolve().parents[2]/'Scripts/build-app.sh').read_text()
  lines='\n'.join(x for x in s.splitlines() if x.startswith('SIGN_OPTIONS=') or x.startswith('[[ "$SIGN_IDENTITY" == "-" ]] || SIGN_OPTIONS='))
  p=subprocess.run(['/bin/bash','-c','set -euo pipefail; SIGN_IDENTITY=-; '+lines+'\nprintf "%s\\n" "${SIGN_OPTIONS[@]}"'],capture_output=True,text=True)
  self.assertEqual(p.returncode,0,p.stderr);self.assertIn('--timestamp=none',p.stdout);self.assertNotIn('runtime',p.stdout)
 def testDeveloperIDRetainsHardenedRuntime(self):
  s=(Path(__file__).resolve().parents[2]/'Scripts/build-app.sh').read_text()
  lines='\n'.join(x for x in s.splitlines() if x.startswith('SIGN_OPTIONS=') or x.startswith('[[ "$SIGN_IDENTITY" == "-" ]] || SIGN_OPTIONS='))
  p=subprocess.run(['/bin/bash','-c','set -euo pipefail; SIGN_IDENTITY=fixture-developer-id; '+lines+'\nprintf "%s\\n" "${SIGN_OPTIONS[@]}"'],capture_output=True,text=True)
  self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout.splitlines(),['--options','runtime'])
