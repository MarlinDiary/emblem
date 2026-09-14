import importlib.util,json,os,plistlib,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('native_oauth',Path(__file__).resolve().parents[2]/'Scripts/apply-native-oauth-config.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class NativeOAuthTests(unittest.TestCase):
    def run_config(self,obj):
        with tempfile.TemporaryDirectory() as d:
            src=Path(d)/'native.json';dest=Path(d)/'Info.plist'
            src.write_text(json.dumps(obj));dest.write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.mailportrait.app'}))
            m.apply(src,dest);return plistlib.loads(dest.read_bytes())
    def test_native_configuration_only(self):
        with patch.dict(os.environ,{'EMBLEM_GOOGLE_CLIENT_ID':'a.apps.googleusercontent.com'}):
            result=self.run_config({'installed':{'client_id':'a.apps.googleusercontent.com','client_secret':'public-native-fixture'}})
        self.assertEqual(result['EmblemGoogleClientSecret'],'public-native-fixture')
        self.assertEqual(result['CFBundleIdentifier'],'org.mailportrait.app')
    def test_account_tokens_web_clients_and_mismatches_rejected(self):
        cfg={'client_id':'a.apps.googleusercontent.com','client_secret':'public-native-fixture'}
        for obj in [{'web':cfg},{'installed':dict(cfg,refresh_token='private-fixture')},{'type':'service_account'},{'installed':dict(cfg,client_secret='')}]:
            with self.subTest(obj=list(obj)),self.assertRaises(ValueError):self.run_config(obj)
        with patch.dict(os.environ,{'EMBLEM_GOOGLE_CLIENT_ID':'b.apps.googleusercontent.com'}),self.assertRaises(ValueError):self.run_config({'installed':cfg})
