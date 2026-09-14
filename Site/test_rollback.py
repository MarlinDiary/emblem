import unittest
from rollback import rollback, DOMAINS, PREFIX, SCRIPT

class RollbackTests(unittest.TestCase):
    def setUp(self):
        self.domains=[{'hostname':host,'id':domain_id,'service':SCRIPT} for host,domain_id in DOMAINS.items()]
        self.scripts=[{'id':SCRIPT},{'id':'other-website'}]
        self.calls=[]
    def api(self,method,path):
        self.calls.append((method,path))
        if method=='DELETE' and path.startswith(PREFIX+'/domains/'):
            domain_id=path.rsplit('/',1)[-1]
            self.domains=[d for d in self.domains if d['id']!=domain_id]
        elif method=='DELETE' and path==PREFIX+'/scripts/'+SCRIPT:self.scripts=[s for s in self.scripts if s['id']!=SCRIPT]
        elif method!='GET':raise AssertionError('Unexpected mutation')
        return {'success':True,'result':self.domains if '/domains' in path else self.scripts}
    def test_read_only_default(self):
        rollback(self.api)
        self.assertTrue(all(m=='GET' for m,p in self.calls))
    def test_withdraw_and_verify_keeps_other_sites(self):
        rollback(self.api,True)
        self.assertEqual(self.domains,[])
        self.assertEqual(self.scripts,[{'id':'other-website'}])
    def test_guard_changed_binding(self):
        self.domains[0]['service']='other-website'
        with self.assertRaises(RuntimeError):rollback(self.api,True)
        self.assertTrue(all(m=='GET' for m,p in self.calls))
    def test_idempotent_absence(self):
        self.domains=[];self.scripts=[{'id':'other-website'}]
        rollback(self.api,True)
        self.assertTrue(all(m=='GET' for m,p in self.calls))

if __name__=='__main__':unittest.main()
