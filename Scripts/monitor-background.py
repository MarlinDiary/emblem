#!/usr/bin/env python3
"""Bounded, resumable, read-only background acceptance. Never loads Keychain,
mail bodies, address-book contents or history identifiers into the evidence log.
Run under a temporary user LaunchAgent to observe natural sleep/login/reboots.
"""
import argparse, datetime, hashlib, json, math, os, plistlib, statistics, subprocess, time, urllib.request
from pathlib import Path
OFFSET = 978307200

def read(path):
    try: return json.loads(path.read_text())
    except (OSError, ValueError): return {}

def sample(root, now, online):
    accounts=read(root/'gmail.json').get('accounts',[])
    sync=read(root/'mail-sync.json')
    enabled=sync.get('enabled') is True and sync.get('background') is True
    healthy=valid=0;renewals=[];check_ages=[]
    for account in accounts:
        push=account.get('push',{});cursor=account.get('cursor',{})
        file=root/'gmail-push-presence'/(hashlib.sha256(str(account.get('id','')).encode()).hexdigest()+'.json')
        presence=read(file)
        watch=push.get('watchExpiration',0)+OFFSET
        registration=push.get('registrationExpiration',0)+OFFSET
        heartbeat=presence.get('lastAlive',0)+OFFSET
        is_valid=watch>now and registration>now
        valid += int(is_valid)
        healthy += int(is_valid and -60<=now-heartbeat<=120 and not account.get('pushIssue'))
        if push.get('lastWatchRenewal') is not None:renewals.append(push['lastWatchRenewal']+OFFSET)
        if cursor.get('lastCheck') is not None:check_ages.append(max(0,now-cursor['lastCheck']-OFFSET))
    processes=[]
    try:
        output=subprocess.check_output(['ps','-ax','-o','pid=,%cpu=,rss=,command='],text=True)
        for line in output.splitlines():
            fields=line.strip().split(None,3)
            if len(fields)!=4 or '/Emblem.app/Contents/MacOS/Emblem' not in fields[3]:continue
            cmd=fields[3]
            role='helper' if '--background-sync-agent' in cmd else 'worker' if '--mail-scan-worker' in cmd or '--scan-mail-worker' in cmd else 'foreground'
            processes.append(dict(role=role,pid=int(fields[0]),cpu=float(fields[1]),rssMB=round(int(fields[2])/1024,2)))
    except (OSError,ValueError,subprocess.SubprocessError):pass
    try:boot=subprocess.check_output(['sysctl','-n','kern.boottime'],text=True).strip()
    except (OSError,subprocess.SubprocessError):boot='unknown'
    try:build=plistlib.loads(Path('/Applications/Emblem.app/Contents/Info.plist').read_bytes()).get('CFBundleVersion','unknown')
    except (OSError,ValueError):build='unknown'
    return dict(installedBuild=build,epoch=now,at=datetime.datetime.fromtimestamp(now,datetime.timezone.utc).isoformat(),
                boot=boot,online=online,syncExpected=enabled,accountCount=len(accounts),validWatches=valid,healthyPushAccounts=healthy,
                watchRenewalEpochs=sorted(renewals),maxCheckAgeSeconds=round(max(check_ages,default=0),1),processes=processes)

def summary(points, duration, complete):
    eligible=[p for p in points if p['online'] is True and p['syncExpected'] and p['accountCount']>0]
    healthy=[p for p in eligible if p['healthyPushAccounts']==p['accountCount'] and any(x['role']=='helper' for x in p['processes'])]
    idle=[p for p in points if not any(x['role']=='worker' for x in p['processes'])]
    cpu=[sum(x['cpu'] for x in p['processes']) for p in idle if p['processes']]
    memory=[sum(x['rssMB'] for x in p['processes']) for p in idle if p['processes']]
    def percentile(values,q):return sorted(values)[min(len(values)-1,math.ceil(len(values)*q)-1)] if values else None
    first=points[0] if points else {};last=points[-1] if points else {}
    elapsed=last.get('epoch',0)-first.get('epoch',0)
    fraction=len(healthy)/len(eligible) if eligible else None
    renewed=any(p.get('watchRenewalEpochs')!=first.get('watchRenewalEpochs') for p in points)
    checks=dict(singleInstalledBuild=len(set(p.get('installedBuild','fixture') for p in points))==1,elapsedWindow=complete and elapsed>=duration-1,pushAvailability=fraction is not None and fraction>=0.99,
                idleCPU=bool(cpu) and statistics.median(cpu)<2 and percentile(cpu,.95)<8,
                memory=bool(memory) and percentile(memory,.95)<500,automaticWatchRenewal=renewed)
    return dict(status='completed' if complete else 'running',requestedSeconds=duration,elapsedSeconds=round(elapsed,1),samples=len(points),
                installedBuilds=sorted(set(p.get('installedBuild','fixture') for p in points)),eligibleOnlineSamples=len(eligible),pushHealthyFraction=fraction,idleCPUMedian=statistics.median(cpu) if cpu else None,
                idleCPUP95=percentile(cpu,.95),rssMBP95=percentile(memory,.95),distinctBoots=len(set(p['boot'] for p in points)),
                longGaps=sum(b['epoch']-a['epoch']>180 for a,b in zip(points,points[1:])),watchRenewalObserved=renewed,
                checks=checks,accepted=complete and all(checks.values()),
                boundary='Natural awake/online observation; gaps do not prove sleep or forced reboot. Short runs are not multi-day acceptance.',
                contactsReads=0,contactsWrites=0,keychainReads=0,mailRequests=0)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path.home()/'Library/Application Support/Emblem')
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--duration',type=float,default=259200)
    parser.add_argument('--interval',type=float,default=60);parser.add_argument('--offline-fixture',action='store_true')
    args=parser.parse_args()
    if not 1<=args.duration<=604800 or not 0.1<=args.interval<=3600:parser.error('Use bounded duration/interval')
    args.output.mkdir(parents=True,exist_ok=True);os.chmod(args.output,0o700)
    log=args.output/'samples.jsonl';points=[]
    if log.exists():
        for line in log.read_text().splitlines():
            try:points.append(json.loads(line))
            except ValueError:pass
    started=points[0]['epoch'] if points else time.time();online=None;next_network=0
    while True:
        now=time.time()
        if args.offline_fixture:online=False
        elif now>=next_network:
            try:
                with urllib.request.urlopen('https://push.emblem.protoyard.com/ready',timeout=5) as r:online=r.status==200
            except Exception:online=False
            next_network=now+300
        points.append(sample(args.root,now,online))
        with log.open('a') as f:f.write(json.dumps(points[-1],sort_keys=True)+'\n')
        os.chmod(log,0o600)
        complete=now-started>=args.duration
        result=summary(points,args.duration,complete)
        temp=args.output/'summary.tmp';temp.write_text(json.dumps(result,indent=2)+'\n');os.chmod(temp,0o600);temp.replace(args.output/'summary.json')
        if complete or (args.output/'STOP').exists():break
        time.sleep(min(args.interval,max(.1,args.duration-(now-started))))
    print(json.dumps(result,sort_keys=True));return 0
if __name__=='__main__':raise SystemExit(main())
