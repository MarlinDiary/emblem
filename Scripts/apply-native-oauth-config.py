#!/usr/bin/env python3
"""Bundle only public Google installed-application configuration, never tokens."""
import json, os, plistlib, sys
from pathlib import Path

def apply(source, destination):
    raw=Path(source).read_bytes()
    if len(raw)>64000: raise ValueError('Desktop application configuration is oversized')
    obj=json.loads(raw)
    allowed={'client_id','client_secret','project_id','auth_uri','token_uri','auth_provider_x509_cert_url','redirect_uris'}
    if set(obj)!={'installed'} or not isinstance(obj['installed'],dict) or set(obj['installed'])-allowed:
        raise ValueError('Only a Google Desktop installed-application configuration is accepted')
    cfg=obj['installed'];cid=cfg.get('client_id');secret=cfg.get('client_secret')
    if not isinstance(cid,str) or not cid.endswith('.apps.googleusercontent.com') or any(x.isspace() for x in cid):
        raise ValueError('Invalid Desktop application identifier')
    if not isinstance(secret,str) or not secret.strip() or any(x.isspace() for x in secret):
        raise ValueError('Incomplete Desktop application configuration')
    expected=os.environ.get('EMBLEM_GOOGLE_CLIENT_ID')
    if expected and cid!=expected: raise ValueError('Desktop application configuration does not match this build')
    target=Path(destination);info=plistlib.loads(target.read_bytes())
    if info.get('EmblemGoogleClientID',cid)!=cid: raise ValueError('Desktop application identifier mismatch')
    info.update(EmblemGoogleClientID=cid,EmblemGoogleClientSecret=secret)
    target.write_bytes(plistlib.dumps(info))

if __name__=='__main__':
    try: apply(*sys.argv[1:])
    except Exception: sys.exit('Public Desktop application configuration validation failed')
    print('NATIVE_OAUTH_CONFIG=COMPLETE USER_CREDENTIALS_BUNDLED=0')
