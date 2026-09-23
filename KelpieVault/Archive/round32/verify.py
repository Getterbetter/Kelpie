import json,socket,os,time,select
SOCK=os.path.expanduser('~/.config/herdr/herdr.sock')
def conn():
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(SOCK); return s
def readline(s,timeout=5):
    buf=b''; s.settimeout(timeout)
    while not buf.endswith(b'\n'):
        try: c=s.recv(65536)
        except socket.timeout: return None
        if not c: return buf.decode() if buf else ''
        buf+=c
    return buf.decode()
def rpc(m,p=None,id='r32'):
    s=conn(); s.sendall((json.dumps({"id":id,"method":m,"params":p if p is not None else {}})+"\n").encode()); l=readline(s,15); s.close(); return json.loads(l)
out={}
# B one request per connection
s=conn(); s.sendall(b'{"id":"a","method":"ping","params":{}}\n'); first=readline(s); time.sleep(0.2)
try:
    s.sendall(b'{"id":"b","method":"ping","params":{}}\n'); second=readline(s,2); out['B_second_write']=repr(second)
except Exception as e: out['B_second_write']='exception '+type(e).__name__+' '+str(e)
s.close()
# C malformed
s=conn(); s.sendall(b'{"id":"mal","method":"ping"}\n'); out['C_missing_params']=readline(s); s.close()
s=conn(); s.sendall(b'this is not json\n'); out['C_not_json']=readline(s); s.close()
# D error shape
out['D_unknown_method']=rpc('no.such.method')
# create scratch workspace
cwd=os.environ['VCWD']
w=rpc('workspace.create',{"cwd":cwd,"label":"kelpie-verify-r32","focus":False}); out['ws_create']=w
wid=w['result']['workspace']['workspace_id'] if 'workspace' in w.get('result',{}) else None
print(json.dumps(w)[:800])
json.dump(out,open(os.environ['OUT'],'w'),indent=1)
