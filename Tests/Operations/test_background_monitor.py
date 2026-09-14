import importlib.util,json,subprocess,tempfile,unittest
from pathlib import Path
SCRIPT=Path(__file__).resolve().parents[2]/'Scripts/monitor-background.py'
spec=importlib.util.spec_from_file_location('monitor',SCRIPT);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class BackgroundMonitorTests(unittest.TestCase):
 def testLaunchdRelativeNameAndNoShellFalsePositive(self):
  self.assertEqual(m.process_role('Emblem --background-sync-agent'),'helper')
  self.assertEqual(m.process_role('/Applications/Emblem.app/Contents/MacOS/Emblem --mail-scan-worker'),'worker')
  self.assertEqual(m.process_role('/Applications/Emblem.app/Contents/MacOS/Emblem --contact-mutation-worker'),'worker')
  self.assertIsNone(m.process_role('/bin/zsh -lc echo /Applications/Emblem.app/Contents/MacOS/Emblem'))
 def testShortWindowDoesNotClaimMultiDayAcceptance(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);out=p/'out'
   r=subprocess.run(['python3',str(SCRIPT),'--root',str(p),'--output',str(out),'--duration','1','--interval','.25','--offline-fixture'],capture_output=True,text=True)
   self.assertEqual(r.returncode,0,r.stderr);s=json.loads((out/'summary.json').read_text())
   self.assertEqual(s['status'],'completed');self.assertFalse(s['accepted']);self.assertGreaterEqual(s['samples'],3)
   text=(out/'samples.jsonl').read_text();self.assertNotIn('email',text);self.assertNotIn('historyID',text)
 def testThresholdsAndAutomaticRenewalAreObservedNotAssumed(self):
  def point(t,renew):return dict(epoch=t,online=True,syncExpected=True,accountCount=1,healthyPushAccounts=1,watchRenewalEpochs=[renew],boot='one',processes=[dict(role='helper',cpu=.1,rssMB=100)])
  points=[point(0,0),point(60,0),point(259200,86400)]
  self.assertFalse(m.summary(points,259200,False)['accepted'])
  self.assertTrue(m.summary(points,259200,True)['accepted'])
  points[-1]['healthyPushAccounts']=0
  self.assertFalse(m.summary(points,259200,True)['accepted'])
