#!/usr/bin/env python3
import zipfile, zlib, sys, os, json
# A valid stored ZIP with one sparse 4 GB payload and 99,999 empty entries. Compute the CRC over zero
# chunks; filesystem holes are real zero data, not fake metadata or an artificially inflated footer.
path=sys.argv[1]
size=4_000_000_000
chunk=bytes(4*1024*1024)
crc=0
remaining=size
while remaining:
    n=min(remaining,len(chunk)); crc=zlib.crc32(chunk[:n],crc); remaining-=n
with open(path,'x+b') as f:
    with zipfile.ZipFile(f,'w',allowZip64=True) as z:
        info=zipfile.ZipInfo('payload.bin'); info.create_system=3; info.external_attr=0o100644<<16
        info.file_size=size; info.compress_size=size; info.CRC=crc; info.header_offset=0
        f.write(info.FileHeader(zip64=True))
        f.seek(size,1)
        z.filelist.append(info); z.NameToInfo[info.filename]=info; z.start_dir=f.tell(); z._didModify=True
        for i in range(99_999): z.writestr(f'f{i:05d}.txt',b'')
print(json.dumps({'bytes':os.stat(path).st_size,'allocatedBytes':os.stat(path).st_blocks*512,'entries':100_000}))
