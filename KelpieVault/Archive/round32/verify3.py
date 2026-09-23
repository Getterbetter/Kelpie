import json,socket,os,time
exec(open(os.environ['SP']+'/verify.py').read().split('out={}')[0])
out={}
panes=rpc('pane.list',{"workspace_id":"wF"})['result']
pl=panes.get('panes',panes)
P2=[p['pane_id'] for p in pl if p['tab_id']=='wF:t2'][0]; out['P2']=P2
# status subscription before start
s=conn(); s.sendall((json.dumps({"id":"st","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.agent_status_changed","pane_id":P2},{"type":"pane.agent_detected"}]}})+"\n").encode()); out['K_sub_ack']=readline(s).strip()
t0=time.time(); r=rpc('agent.start',{"name":"kv32","kind":"claude","pane_id":P2}); out['K_start_ms']=int((time.time()-t0)*1000); out['K_start']=r
ev=[]; end=time.time()+12
while time.time()<end:
    l=readline(s,0.5)
    if l: ev.append(l.strip()[:250])
out['K_events_12s']=ev; s.close()
out['K_agent_get']=str(rpc('agent.get',{"target":"kv32"}))[:500]
for n in ["Bad","ok_name-1","1abc","a"*33,"a"*32]:
    out['L_agent_rename_'+n[:12]+'_%d'%len(n)]=rpc('agent.rename',{"target":P2,"name":n}).get('error',{}).get('code','ok')
out['L_agent_rename_null']=rpc('agent.rename',{"target":P2,"name":None}).get('error',{}).get('code','ok')
out['L_agent_rename_omitted']=rpc('agent.rename',{"target":P2}).get('error',{}).get('code','ok')
out['L_agent_after_clear']=str(rpc('agent.get',{"target":P2}).get('result',{}))[:300]
json.dump(out,open(os.environ['OUT'],'w'),indent=1)
