import json,socket,os,time
exec(open(os.environ['SP']+'/verify.py').read().split('out={}')[0])
out={}; W='wF'; P='wF:p1'
def sub(subs,read_for=3.0):
    s=conn(); s.sendall((json.dumps({"id":"sub32","method":"events.subscribe","params":{"subscriptions":subs}})+"\n").encode())
    lines=[]; end=time.time()+read_for
    while time.time()<end:
        l=readline(s,max(0.1,end-time.time()))
        if l is None: break
        if l=='': lines.append('<EOF>'); break
        lines.append(l.strip())
    return s,lines
# E lifecycle live-only: tab.create happened before subscribe? create a tab now, then subscribe, expect no replay
t=rpc('tab.create',{"workspace_id":W,"label":"pre-sub","focus":False}); out['E_pre_tab']=t['result']['tab']['tab_id'] if 'result' in t else t
time.sleep(0.5)
s,lines=sub([{"type":"tab.created"},{"type":"tab.closed"},{"type":"workspace.renamed"}],1.5)
out['E_after_subscribe_before_action']=lines
t2=rpc('tab.create',{"workspace_id":W,"label":"post-sub","focus":False}); out['E_post_tab']=t2['result']['tab']['tab_id']
more=[]; end=time.time()+2
while time.time()<end:
    l=readline(s,0.3)
    if l: more.append(l.strip())
out['E_after_action']=more
# L renames while subscribed
out['L_ws_rename_empty']=rpc('workspace.rename',{"workspace_id":W,"label":""})
out['L_ws_rename_long']=str(rpc('workspace.rename',{"workspace_id":W,"label":"x"*500}))[:200]
rpc('workspace.rename',{"workspace_id":W,"label":"kelpie-verify-r32"})
end=time.time()+1.5; ev=[]
while time.time()<end:
    l=readline(s,0.3)
    if l: ev.append(l.strip()[:300])
out['L_rename_events']=ev
s.close()
# F all-or-nothing
s,lines=sub([{"type":"workspace.created"},{"type":"pane.agent_status_changed","pane_id":"wF:p999"}],1.5); s.close(); out['F_dead_pane']=lines
# G output_changed not subscribable
s,lines=sub([{"type":"pane.output_changed","pane_id":P}],1.5); s.close(); out['G_output_changed']=[l[:300] for l in lines]
# H pane.read
rpc('pane.send_text',{"pane_id":P,"text":"for i in $(seq 1 1500); do echo line$i; done\n"}); time.sleep(2)
r=rpc('pane.read',{"pane_id":P,"source":"recent","lines":2000})
res=r.get('result',{}); rd=res.get('read',{})
out['H_keys']=list(res.keys()); out['H_read_keys']={k:(v if k!='text' else len(v.splitlines())) for k,v in rd.items()}
r=rpc('pane.read',{"pane_id":P,"source":"recent"}); out['H_default_lines']=len(r['result']['read']['text'].splitlines())
# I events.wait param
out['I_wait_wrong_param']=rpc('events.wait',{"match":{"event":"workspace_created"},"timeout_ms":500})
out['I_wait_match_event']=rpc('events.wait',{"match_event":{"event":"workspace_created"},"timeout_ms":500})
out['I_wait_pane_status']=rpc('events.wait',{"match_event":{"event":"pane_agent_status_changed","pane_id":P},"timeout_ms":500})
# J key parsing
for k in ["ctrl-c","ctrl+c","C-c","CTRL+C","Enter","esc"]:
    out['J_'+k]=rpc('pane.send_input',{"pane_id":P,"keys":[k]}).get('error',{}).get('code','ok')
json.dump(out,open(os.environ['OUT'],'w'),indent=1)
