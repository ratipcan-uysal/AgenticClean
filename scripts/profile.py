#!/usr/bin/env python3
"""Read-only, bounded measurement of one AgenticClean PID; stores no process history."""
import argparse, ctypes as C, json, pathlib, subprocess, tempfile, time, datetime

class Process(C.Structure):
    _fields_=[('pid',C.c_int32),('parent',C.c_int32),('uid',C.c_uint32),
              ('start_seconds',C.c_uint64),('start_microseconds',C.c_uint64),('cpu_ns',C.c_uint64),
              ('resident',C.c_uint64),('footprint',C.c_uint64),('footprint_valid',C.c_int),('disk_read_bytes',C.c_uint64),('disk_write_bytes',C.c_uint64),('disk_valid',C.c_int),('path',C.c_char*4096)]
class System(C.Structure):
    _fields_=[(k,C.c_uint64) for k in ['cpu_user','cpu_system','cpu_idle','cpu_nice','wired','compressed','active','inactive','free_bytes','swapins','swapouts','compressions','decompressions','page_size']]+[('pressure',C.c_int),('cpu_valid',C.c_int),('memory_valid',C.c_int)]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--pid',type=int,required=True)
    parser.add_argument('--duration',type=float,default=600)
    parser.add_argument('--output',type=pathlib.Path,required=True)
    args=parser.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='cleaner-measure-') as folder:
        library=pathlib.Path(folder)/'ProcessKit.dylib'
        subprocess.run(['clang','-dynamiclib',str(root/'Sources/ProcessKit/ProcessKit.c'),'-I'+str(root/'Sources/ProcessKit/include'),'-o',str(library)],check=True)
        lib=C.CDLL(str(library));lib.cleaner_read.argtypes=[C.c_int32,C.POINTER(Process)];lib.cleaner_read.restype=C.c_int
        lib.cleaner_system.restype=System
        started=time.monotonic();samples=[];identity=None;next_report=60
        while True:
            raw=Process()
            if lib.cleaner_read(args.pid,C.byref(raw)) != 1: raise RuntimeError('Cleaner process could not be read; measurement invalid')
            executable=bytes(raw.path).decode()
            if not executable.endswith(('/AgenticClean.app/Contents/MacOS/Cleaner', '/Cleaner.app/Contents/MacOS/Cleaner')): raise RuntimeError('This script measures AgenticClean only')
            current=(raw.start_seconds,raw.start_microseconds)
            if identity is not None and identity != current: raise RuntimeError('PID reused; measurement invalid')
            identity=current
            if raw.footprint_valid != 1: raise RuntimeError('Footprint unavailable; measurement invalid')
            system=lib.cleaner_system()
            samples.append(dict(elapsed=time.monotonic()-started,cpu_ns=raw.cpu_ns,footprint=raw.footprint,pressure=system.pressure,
                                system_ticks=[system.cpu_user,system.cpu_system,system.cpu_nice,system.cpu_idle]))
            if samples[-1]['elapsed'] >= next_report:
                elapsed_so_far=samples[-1]['elapsed']-samples[0]['elapsed']
                print(json.dumps(dict(progress_seconds=round(elapsed_so_far),average_cpu_percent=(raw.cpu_ns-samples[0]['cpu_ns'])/1e9/elapsed_so_far*100,footprint_mib=raw.footprint/1048576,pressure=system.pressure)),flush=True)
                next_report += 60
            if samples[-1]['elapsed'] >= args.duration: break
            time.sleep(min(5,args.duration-samples[-1]['elapsed']))
        elapsed=samples[-1]['elapsed']-samples[0]['elapsed']
        cpu=(samples[-1]['cpu_ns']-samples[0]['cpu_ns'])/1e9/elapsed*100
        peak=max(s['footprint'] for s in samples)/1048576
        first,last=samples[0]['system_ticks'],samples[-1]['system_ticks']
        deltas=[(b-a) % 2**32 for a,b in zip(first,last)]
        system_cpu=(1-deltas[3]/sum(deltas))*100 if sum(deltas) else None
        result=dict(measured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),executable=executable,
                    duration_seconds=elapsed,samples=len(samples),average_single_core_cpu_percent=cpu,
                    average_system_cpu_percent=system_cpu,max_footprint_mib=peak,
                    first_footprint_mib=samples[0]['footprint']/1048576,last_footprint_mib=samples[-1]['footprint']/1048576,
                    pressure_levels=sorted(set(s['pressure'] for s in samples)),
                    cpu_target_pass=cpu<1,footprint_target_pass=peak<100,full_duration_pass=elapsed>=600,
                    readings=samples)
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k!='readings'},indent=2),flush=True)
if __name__=='__main__': main()
