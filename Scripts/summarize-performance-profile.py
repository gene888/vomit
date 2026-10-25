#!/usr/bin/env python3
"""Summarize raw StageCue measurements without third-party dependencies."""
import json, math, statistics, sys
from pathlib import Path
from collections import defaultdict
p = Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[1]/'work/PerformanceBaseline/results.json'
r=json.loads(p.read_text())
if r.get('status') != 'complete': raise SystemExit('Workload has not completed; refusing to summarize partial results.')
def stats(values):
    a=sorted(values)
    return dict(n=len(a), median=statistics.median(a), p95=a[math.ceil(.95*len(a))-1], maximum=a[-1], mean=statistics.mean(a), minimum=a[0])
s={k:r[k] for k in ['date','configuration','memoryBeforeEngines','memoryIdleEnginesAndCanvases','largeShow','largeShowIdleCPUPercentOneCore','memoryEight60SecondAudioVoices','memoryAfterStop','audioNodesAfterStop','audioErrors','videoError','audioConfiguration','canvasConfiguration']}
for key,field in [('audio','firstNonzeroMixerCallbackMs'),('videoStartup','framePublishedMs')]:
    groups=defaultdict(list)
    for row in r[key]: groups[row['file']].append(row[field])
    s[key]={file:stats(values) for file,values in groups.items()}
s['audioRenderTimestampMs']={file:stats([row['firstNonzeroRenderTimestampMs'] for row in r['audio'] if row['file']==file]) for file in s['audio']}
s['audioTriggerToLoaderTaskMs']={file:stats([row['triggerToLoaderTaskMs'] for row in r['audio'] if row['file']==file]) for file in s['audio']}
s['audioInspectionAndDispatchMs']={file:stats([row['inspectionAndDispatchMs'] for row in r['audio'] if row['file']==file]) for file in s['audio']}
s['audioDecodeMs']={file:stats([row['decodeMs'] for row in r['audio'] if row['file']==file]) for file in s['audio']}
s['audioGraphSetupMs']={file:stats([row['graphSetupMs'] for row in r['audio'] if row['file']==file]) for file in s['audio']}
s['actualTapBufferFrames']=sorted({row['tapFrames'] for row in r['audio']})
s['audioLoadAndGraphMs']={file:stats([row['loadAndGraphMs'] for row in r['audio'] if row['file']==file]) for file in s['audio']}
s['videoCanvasCompletedMs']={file:stats([row['canvasRenderCompletedMs'] for row in r['videoStartup'] if row['file']==file]) for file in s['videoStartup']}
s['cpuSimultaneousAVPercentOneCore']=stats([x['cpuPercentOneCore'] for x in r['cpuSimultaneousAV']])
s['steadyAVMemoryFootprintMiB']=stats([x['memory']['footprintMiB'] for x in r['cpuSimultaneousAV']])
s['scheduler']={}
for label in sorted({x['scenario'] for x in r['scheduler']}):
    rows=[x for x in r['scheduler'] if x['scenario']==label]
    batches=defaultdict(list)
    for x in rows: batches[x['deadline']].append(x['actual'])
    s['scheduler'][label]={'latenessMs':stats([x['lateMs'] for x in rows]),'sixteenActionBurstSpreadMs':stats([(max(x)-min(x))*1000 for x in batches.values()]),'bursts':len(batches)}
s['crossfadeOneSecond']={k:stats([x[k] for x in r['crossfadeOneSecond']]) for k in ['triggerToReadyMs','readyToCompleteMs','envelopeStartToCompleteMs','triggerToCompleteMs']}
for key,fps in [('frames1080p30',30),('frames1080p60',60),('framesDuringRealBusActions',30)]:
    rows=r[key]; intervals=[]; skipped=0; observedIntervals=0; resets=0
    for a,b in zip(rows,rows[1:]):
        intervals.append((b['host']-a['host'])*1000)
        d=b['pts']-a['pts']
        if d<=0: resets+=1; continue
        count=round(d*fps)
        skipped+=max(0,count-1); observedIntervals+=1
    s[key]={'decodedFrameObservations':len(rows),'elapsedSeconds':rows[-1]['host']-rows[0]['host'],'observedFPS':(len(rows)-1)/(rows[-1]['host']-rows[0]['host']),
            'frameCallbackIntervalMs':stats(intervals),'intervalsOver50ms':sum(x>50 for x in intervals),
            'unobservedSourceFramesWithinContinuousPTS':skipped,'sourceFrameIntervalsWithinContinuousPTS':skipped+observedIntervals,'ptsResets':resets}
if 'realMixerCommandCostMs' in r:
    s['realMixerCommandCostMs']=stats(r['realMixerCommandCostMs'])
    for key in ['realMixerWorkloadCPUPercentOneCore','realMixerMemoryBefore','realMixerMemoryAfter','audioNodesBeforeRealMixer','audioNodesAfterRealMixer','audioVoicesAfterRealMixer','decodedBytesAfterRealMixer']: s[key]=r[key]
output=p.with_name('summary.json'); output.write_text(json.dumps(s,indent=2)+'\n')
print(json.dumps(s,indent=2))
