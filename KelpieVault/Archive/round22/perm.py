import json,time,sys
from rpc import rpc
def screen(n=14): return rpc('pane.read',{'pane_id':'wG:p1','source':'visible','lines':n})['result']['read']['text']
def st(): return rpc('agent.get',{'target':'wG:p1'})['result']['agent']['agent_status']
def mode(): return [l for l in screen(3).splitlines() if 'mode' in l]
rpc('agent.send_keys',{'target':'wG:p1','keys':['shift+tab']}); time.sleep(1.2); print('mode after 1 shift+tab:',mode())
if not any('manual' in m or 'default' in m for m in mode()):
    rpc('agent.send_keys',{'target':'wG:p1','keys':['shift+tab']}); time.sleep(1.2); print('mode after 2:',mode())
rpc('agent.prompt',{'target':'wG:p1','text':'Use the Bash tool to run exactly: touch /tmp/kelpie-spike-perm3.txt . Then say done.'})
t0=time.time()
while time.time()-t0<25:
    s=st()
    if s=='blocked':
        print(f'blocked at {time.time()-t0:.1f}s'); print('--- screen at blocked ---'); print(screen(22)); break
    time.sleep(0.5)
else: print('never blocked; status',st())
key=sys.argv[1] if len(sys.argv)>1 else 'enter'
rpc('agent.send_keys',{'target':'wG:p1','keys':[key]}); print('sent',key)
t1=time.time()
while time.time()-t1<20:
    s=st()
    if s in('done','idle'): print(f'{s} at {time.time()-t1:.1f}s after key'); break
    time.sleep(0.5)
else: print('still',st()); print(screen(12))
