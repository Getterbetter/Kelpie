#!/usr/bin/env python3
import json,socket,sys,os
def rpc(method,params=None):
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(os.path.expanduser('~/.config/herdr/herdr.sock'))
    s.sendall((json.dumps({"id":"k","method":method,"params":params or {}})+"\n").encode())
    buf=b''
    while not buf.endswith(b'\n'):
        c=s.recv(65536)
        if not c: break
        buf+=c
    s.close(); return json.loads(buf)
if __name__=='__main__':
    print(json.dumps(rpc(sys.argv[1], json.loads(sys.argv[2]) if len(sys.argv)>2 else {}),indent=1))
