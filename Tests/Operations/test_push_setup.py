"""Exercise deployment orchestration with disposable CLI stubs, no cloud calls."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("push_config", ROOT / "Scripts/validate-push-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name=Path(sys.argv[0]).name; args=sys.argv[1:]
with open(os.environ['CALLS'], 'a') as file: file.write(json.dumps([name]+args)+'\n')
existing=os.environ.get('EXISTING')=='1'
if name=='gcloud':
    if args[:2]==['projects','describe']:
        if 'value(projectNumber)' in ' '.join(args): print(os.environ.get('MOCK_NUMBER','123456789012'))
        else: print('fixture-project')
    elif 'describe' in args:
        if not existing: sys.exit(1)
        if args[:3]==['pubsub','subscriptions','describe'] and any('value(topic)' in x for x in args):
            print('projects/fixture-project/topics/emblem-gmail-events')
elif name=='wrangler':
    if args[:2]==['secret','list']: print(json.dumps([{'name':'HMAC_SECRET'}] if existing else []))
    elif args[:2]==['secret','put']: sys.stdin.read()  # Never log credentials.
elif name=='curl': print('{"ready":true}')
'''

class PushSetupTests(unittest.TestCase):
    def run_setup(self, existing=False, mismatch=False):
        with tempfile.TemporaryDirectory(prefix='emblem-cloud-stub-') as directory:
            folder=Path(directory)
            for name in ('gcloud','wrangler','curl'):
                file=folder/name; file.write_text(STUB); file.chmod(0o700)
            env=dict(os.environ, PATH=str(folder)+':'+os.environ['PATH'],
                     EMBLEM_WRANGLER=str(folder/'wrangler'), CALLS=str(folder/'calls.jsonl'),
                     EMBLEM_GOOGLE_PROJECT_NUMBER='123456789012',
                     EMBLEM_GOOGLE_CLIENT_ID='123456789012-fixture.apps.googleusercontent.com',
                     EMBLEM_GOOGLE_PROJECT_ID='fixture-project', EXISTING='1' if existing else '0')
            if mismatch: env['MOCK_NUMBER']='999999999999'
            process=subprocess.run(['bash', str(ROOT/'Scripts/configure-gmail-push.sh')], env=env, capture_output=True, text=True)
            calls=[json.loads(line) for line in (folder/'calls.jsonl').read_text().splitlines()]
            return process,calls

    def test_new_resources_are_keyless_and_narrowly_scoped(self):
        result,calls=self.run_setup()
        self.assertEqual(result.returncode,0,result.stderr)
        text=json.dumps(calls)
        self.assertIn('pubsub.publisher',text)
        self.assertIn('iam.serviceAccountTokenCreator',text)
        grants=[c for c in calls if 'add-iam-policy-binding' in c]
        self.assertTrue(all(c[1:3] != ['projects','add-iam-policy-binding'] for c in grants))
        self.assertFalse(any(c[1:4]==['iam','service-accounts','keys'] for c in calls))
        self.assertTrue(any(c[:3]==['wrangler','secret','put'] and c[-1]=='HMAC_SECRET' for c in calls))
        self.assertTrue(any('subscriptions' in c and 'create' in c for c in calls))
        self.assertIn('GMAIL_PUSH_RESOURCES=CONFIGURED',result.stdout)

    def test_existing_resources_preserve_hmac_and_modify_only_named_subscription(self):
        result,calls=self.run_setup(existing=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(c[:3]==['wrangler','secret','put'] and c[-1]=='HMAC_SECRET' for c in calls))
        self.assertTrue(any('modify-push-config' in c for c in calls))
        self.assertFalse(any('topics' in c and 'create' in c for c in calls))

    def test_project_mismatch_stops_before_cloud_mutations(self):
        result,calls=self.run_setup(mismatch=True)
        self.assertEqual(result.returncode,4)
        self.assertEqual(len(calls),1)

    def test_build_configuration_rejects_partial_or_credential_bearing_values(self):
        values=['https://push.emblem.protoyard.com','projects/fixture-project/topics/emblem-gmail-events',
                '123456789012','123456789012-fixture.apps.googleusercontent.com']
        self.assertTrue(config.valid(values))
        for endpoint in ('http://push.emblem.protoyard.com','https://user:password@push.emblem.protoyard.com',
                         'https://push.emblem.protoyard.com:8443','https://push.emblem.protoyard.com/v1?token=fixture'):
            self.assertFalse(config.valid([endpoint]+values[1:]))
        self.assertFalse(config.valid(values[:2]+['999999999999',values[3]]))
        self.assertFalse(config.valid(['']+values[1:]))

if __name__=='__main__': unittest.main()
