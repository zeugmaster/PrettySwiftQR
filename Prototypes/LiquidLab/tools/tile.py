import struct, zlib, sys
def load(path):
    data=open(path,'rb').read(); pos=8; idat=b''
    while pos < len(data):
        ln,=struct.unpack('>I',data[pos:pos+4]); typ=data[pos+4:pos+8]; body=data[pos+8:pos+8+ln]; pos+=12+ln
        if typ==b'IHDR': w,h,bd,ct=struct.unpack('>IIBB',body[:10])
        elif typ==b'IDAT': idat+=body
    raw=zlib.decompress(idat); bpp=4 if ct==6 else 3; stride=w*bpp; out=[]; prev=bytearray(stride); i=0
    for y in range(h):
        f=raw[i]; i+=1; line=bytearray(raw[i:i+stride]); i+=stride
        for x in range(stride):
            a=line[x-bpp] if x>=bpp else 0; b=prev[x]; c=prev[x-bpp] if x>=bpp else 0
            if f==1: line[x]=(line[x]+a)&255
            elif f==2: line[x]=(line[x]+b)&255
            elif f==3: line[x]=(line[x]+(a+b)//2)&255
            elif f==4:
                p=a+b-c; pa=abs(p-a); pb=abs(p-b); pc=abs(p-c)
                line[x]=(line[x]+(a if pa<=pb and pa<=pc else b if pb<=pc else c))&255
        out.append(bytes(line)); prev=line
    return w,h,bpp,out
def save(path, rows, W):
    raw=b''.join(b'\x00'+bytes(r) for r in rows)
    def chunk(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',W,len(rows),8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw,6))+chunk(b'IEND',b''))
# usage: tile.py out.png cols cellW cellH in1 in2 ... ; each input is a horizontal strip of cells (cellW wide, +6 gap); split into rows of `cols`
out, cols, cw, ch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rows=[]; W=cols*(cw+4)
for f in sys.argv[5:]:
    w,h,bpp,rr=load(f)
    ncell = w // (cw+6)
    for r0 in range(0, ncell, cols):
        for y in range(ch):
            line=bytearray([40]*W*3)
            for k in range(cols):
                ci=r0+k
                if ci>=ncell: break
                x0=ci*(cw+6)
                seg=rr[y][x0*bpp:(x0+cw)*bpp]
                if bpp==4: seg=b''.join(seg[j*4:j*4+3] for j in range(cw))
                line[k*(cw+4)*3:(k*(cw+4)+cw)*3]=seg
            rows.append(line)
        for _ in range(4): rows.append(bytearray([40]*W*3))
save(out, rows, W)
print('ok', out)
