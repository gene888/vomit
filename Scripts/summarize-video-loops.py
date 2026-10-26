#!/usr/bin/env python3
"""Summarize raw software-canvas loop data; a timestamp wrap is not a drop."""
import json, sys, math
from pathlib import Path

def stats(values):
    values=sorted(values)
    return dict(n=len(values), median=values[len(values)//2] if values else None,
                p95=values[max(0,math.ceil(.95*len(values))-1)] if values else None,
                maximum=max(values) if values else None)

def summarize(path):
    raw=json.loads(Path(path).read_text()); rows=[]
    for c in raw.get('cases',[]):
        row={k:c[k] for k in ['name','index','elapsed','cpuPercentOneCore','missingCanvasUpdates','videoError','voices']}
        for kind in ['decoded','presented']:
            frames=c[kind]; gaps=[]; wraps=[]; dropped=0; boundary=[]
            for i,(a,b) in enumerate(zip(frames,frames[1:]),1):
                gap=(b['host']-a['host'])*1000; gaps.append(gap)
                delta=b['pts']-a['pts']
                if delta < -.5: wraps.append(i)
                elif delta > .05: dropped+=max(0,round(delta*30)-1)
            for i in wraps:
                # Include the 3 intervals before and after reset: a restart can
                # produce frame zero promptly then hesitate on frame one.
                local=gaps[max(0,i-4):min(len(gaps),i+3)]
                boundary.append(max(local))
            row[kind]={'frames':len(frames),'fps':(len(frames)-1)/(frames[-1]['host']-frames[0]['host']) if len(frames)>1 else 0,
                       'wraps':len(wraps),'gapsMs':stats(gaps),'boundaryMaximumPerWrapMs':stats(boundary),
                       'intervalsOver50ms':sum(x>50 for x in gaps),'sourceFramesSkippedWithinIterations':dropped}
        row['seekMs']=stats([v['costMs'] for v in c['loops'] if v['phase']=='seekComplete'])
        row['canvasAfterDecodeMs']=stats([(v['host']-v['decodedHost'])*1000 for v in c['presented']])
        row['memoryFirst']=c['memory'][0] if c['memory'] else {};row['memoryLast']=c['memory'][-1] if c['memory'] else {}
        rows.append(row)
    return {'date':raw['date'],'status':raw['status'],'cases':rows,'itemsAfterStop':raw.get('itemsAfterStop'),'memoryAfterStop':raw.get('memoryAfterStop')}

if __name__=='__main__':
    print(json.dumps(summarize(sys.argv[1]),indent=2))
