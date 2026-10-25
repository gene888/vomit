#!/usr/bin/env python3
"""Audio-path timing summary. Raw timelines and render endpoints are retained separately."""
import json,math,statistics,sys
from pathlib import Path
from collections import defaultdict
p=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[1]/'work/PerformanceBaseline/audio-trigger-results.json'
r=json.loads(p.read_text())
if r['status']!='complete': raise SystemExit('Audio workload has not completed')
def stats(a):
 a=sorted(a)
 return dict(n=len(a),median=statistics.median(a),p95=a[math.ceil(.95*len(a))-1],maximum=max(a),minimum=min(a),mean=statistics.mean(a),stddev=statistics.pstdev(a))
pairs={'cueResolution':('state.trigger.enter','state.cue.resolved'), 'selectionPublication':('state.cue.resolved','state.selected.published'),
 'validation':('state.selected.published','state.validated'), 'manualOverrideAndSubmit':('state.validated','state.engine.submit'),
 'engineEntryToTaskCreation':('engine.play.enter','engine.task.create'), 'cleanup':('engine.cleanup.begin','engine.cleanup.end'),
 'taskWait':('engine.task.stored','engine.task.enter'), 'loaderInspectQueue':('engine.task.enter','loader.inspect.enter'),
 'fileInspection':('loader.inspect.enter','loader.inspect.exit'), 'inspectActorReturn':('loader.inspect.exit','engine.inspect.return'),
 'loaderDecodeQueue':('engine.load.submit','loader.load.enter'), 'secondFileInspection':('loader.open.begin','loader.open.end'),
 'decode':('loader.read.begin','loader.read.end'), 'decodeActorReturn':('loader.load.exit','engine.load.return'),
 'graphBeforePublication':('engine.graph.begin','engine.active.publish.begin'), 'activePublication':('engine.active.publish.begin','engine.active.publish.end'),
 'bufferScheduling':('engine.buffer.schedule.begin','engine.buffer.schedule.end'), 'playCommand':('engine.player.play.begin','engine.player.play.end'),
 'graphTotal':('engine.graph.begin','engine.graph.end')}
s={'date':r['date'],'configuration':r['configuration'],'scenarios':{},'memoryBefore':r['memoryBefore'],'memoryAfter':r['memoryAfter'],
 'audioNodesAfterStop':r['audioNodesAfterStop'],'audioErrors':r['audioErrors'],'videoError':r['videoError'],'cache':r['cache']}
for name in sorted({x['scenario'] for x in r['trials']}):
 rows=[x for x in r['trials'] if x['scenario']==name]
 out={'renderMs':stats([x['renderMs'] for x in rows])}
 for key in ['callbackMs','synchronousSubmitMs','lastVoiceRenderMs','onsetSpreadMs']:
  if all(key in x for x in rows):out[key]=stats([x[key] for x in rows])
 phases=defaultdict(list)
 for row in rows:
  # Multi-voice timelines have more than one identity and are kept raw, not collapsed.
  if name=='four-voice-group':continue
  events={e['phase']:e['ms'] for e in row['events']}
  for key,(begin,end) in pairs.items():
   if begin in events and end in events:phases[key].append(events[end]-events[begin])
  if 'engine.player.play.end' in events:phases['playCommandToRender'].append(row['renderMs']-events['engine.player.play.end'])
 out['phaseMs']={k:stats(v) for k,v in phases.items()};s['scenarios'][name]=out
p.with_name('audio-trigger-summary.json').write_text(json.dumps(s,indent=2)+'\n')
print(json.dumps(s,indent=2))
