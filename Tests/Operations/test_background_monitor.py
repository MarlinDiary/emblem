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
   r=subprocess.run(['python3',str(SCRIPT),'--root',str(p),'--output',str(out),'--duration','1','--interval','.25','--offline-fixture','--diagnostic-reports',str(p/'reports')],capture_output=True,text=True)
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

 def testForegroundAndWorkerActivityAreNotCalledHelperIdle(self):
  def point(t,processes):return dict(epoch=t,online=True,syncExpected=True,accountCount=1,healthyPushAccounts=1,watchRenewalEpochs=[86400 if t else 0],boot='one',processes=processes)
  helper=dict(role='helper',cpu=.1,rssMB=100)
  points=[point(0,[helper]),point(60,[helper,dict(role='foreground',cpu=90,rssMB=900)]),point(120,[helper,dict(role='worker',cpu=50,rssMB=700)]),point(259200,[helper])]
  result=m.summary(points,259200,True)
  self.assertEqual(result['idleCPUP95'],.1)
  self.assertEqual(result['rssMBP95'],100)
  self.assertEqual(result['idleSamples'],2)
  self.assertTrue(result['accepted'])

 def testSustainedCheckStallFailsAcceptanceAfterWakeGrace(self):
  def point(t,age,online=True):return dict(epoch=t,online=online,syncExpected=True,accountCount=1,healthyPushAccounts=1,maxCheckAgeSeconds=age,watchRenewalEpochs=[86400 if t>100000 else 0],boot='one',processes=[dict(role='helper',pid=7,cpu=.1,rssMB=100)])
  healthy=[point(t,t%900) for t in range(0,259201,60)]
  result=m.summary(healthy,259200,True)
  self.assertTrue(result['checks']['syncFreshness']);self.assertTrue(result['accepted'])
  # Sleep appears as a sampling gap; the first check after wake is not a stall.
  wake=[point(0,10),point(60,70),point(40000,36000),point(40060,40),point(259200,50)]
  self.assertTrue(m.summary(wake,259200,True)['checks']['syncFreshness'])
  # Offline time cannot be checked; returning online gets the same grace.
  offline=[point(0,10),point(60,3000,False),point(120,3060),point(180,20),point(259200,50)]
  self.assertTrue(m.summary(offline,259200,True)['checks']['syncFreshness'])
  stalled=healthy[:1500]+[point(1500*60+i*60,600+i*60) for i in range(1,3000)]
  result=m.summary(stalled,259200,True)
  self.assertFalse(result['checks']['syncFreshness']);self.assertFalse(result['accepted'])
  self.assertGreater(result['longestCheckAgeSeconds'],2700);self.assertGreater(result['staleCheckSamples'],0)

 def testHelperRestartWithinOneBootFailsAcceptance(self):
  def point(t,pid,boot='one'):return dict(epoch=t,online=True,syncExpected=True,accountCount=1,healthyPushAccounts=1,maxCheckAgeSeconds=30,watchRenewalEpochs=[86400 if t else 0],boot=boot,processes=[dict(role='helper',pid=pid,cpu=.1,rssMB=100)])
  steady=[point(0,7),point(60,7),point(259200,7)]
  self.assertEqual(m.summary(steady,259200,True)['helperRestarts'],0)
  restarted=[point(0,7),point(60,8),point(259200,8)]
  result=m.summary(restarted,259200,True)
  self.assertEqual(result['helperRestarts'],1);self.assertFalse(result['checks']['helperContinuity']);self.assertFalse(result['accepted'])
  rebooted=[point(0,7),point(60,8,'two'),point(259200,8,'two')]
  self.assertEqual(m.summary(rebooted,259200,True)['helperRestarts'],0)

 def testCrashReportsDuringWindowAreListedWithoutContents(self):
  import os
  with tempfile.TemporaryDirectory() as tmp:
   d=Path(tmp)
   for name,when in [('Emblem-2026-09-15-174119.ips',1000),('Emblem-2026-09-10-090000.ips',10),('Other-2026-09-15-174119.ips',1000)]:
    (d/name).write_text('{"private":"not copied"}');os.utime(d/name,(when,when))
   reports=m.crash_reports(d,500,2000)
   self.assertEqual(reports,['Emblem-2026-09-15-174119.ips'])
   result=m.summary([dict(epoch=500,online=True,syncExpected=True,accountCount=1,healthyPushAccounts=1,watchRenewalEpochs=[0],boot='one',processes=[]),dict(epoch=259700,online=True,syncExpected=True,accountCount=1,healthyPushAccounts=1,watchRenewalEpochs=[1],boot='one',processes=[])],259200,True,reports)
   self.assertEqual(result['crashReports'],reports);self.assertFalse(result['checks']['noCrashReports'])
   self.assertNotIn('private',json.dumps(result))
