#!/usr/bin/env python3
# usage: watch.py <pane> <transcript> <seconds>  -- 1 Hz: transcript bytes, new line types, sessions status, herdr status
import json,os,sys,time,glob
from rpc import rpc
pane,tpath,secs=sys.argv[1],os.path.expanduser(sys.argv[2]),int(sys.argv[3])
pid=rpc('pane.process_info',{'pane_id':pane})['result']['process_info']['foreground_processes'][0]['pid']
spath=os.path.expanduser(f'~/.claude/sessions/{pid}.json')
off=os.path.getsize(tpath) if os.path.exists(tpath) else 0
t0=time.time(); last=None
def kinds(chunk):
    out=[]
    for line in chunk.decode('utf-8','replace').splitlines():
        try:o=json.loads(line)
        except: out.append('?'); continue
        t=o.get('type'); m=o.get('message') or {}; c=m.get('content')
        if isinstance(c,list): t+=':'+'+'.join(b.get('type','?') for b in c)
        elif isinstance(c,str): t+=':str'
        out.append(t)
    return out
while time.time()-t0<secs:
    size=os.path.getsize(tpath) if os.path.exists(tpath) else 0
    new=[]
    if size>off:
        with open(tpath,'rb') as f: f.seek(off); new=kinds(f.read(size-off))
        off=size
    try: ss=json.load(open(spath))['status']
    except Exception as e: ss='?'
    hs=rpc('agent.get',{'target':pane})['result']['agent']['agent_status']
    row=(size,ss,hs)
    if new or row!=last: print(f'{time.time()-t0:5.1f}s bytes={size} sessions={ss} herdr={hs} new={new}',flush=True)
    last=row; time.sleep(1)
