#!/usr/bin/env python3
"""Summarize raw resource measurements without equating logical PCM with RSS."""
import json, statistics, sys, math

def stats(values):
    values=sorted(values)
    return dict(count=len(values), median=statistics.median(values), p95=values[math.ceil(.95*len(values))-1], maximum=max(values), minimum=min(values)) if values else {}

def summarize(path):
    raw=json.load(open(path)); result={k:raw[k] for k in ['date','status','configuration']}
    result['audio']={}
    for scenario in sorted({v['scenario'] for v in raw.get('audio',[])}):
        rows=[v for v in raw['audio'] if v['scenario']==scenario]
        result['audio'][scenario]={
            'uniqueDecodedBytes':sorted({v['resources']['uniqueDecodedBytes'] for v in rows}),
            'perVoiceReferencedBytes':sorted({v['resources']['voiceReferencedBytes'] for v in rows}),
            'actualDecodeReads': [v['actualDecodeReads'] for v in rows],
            'activeFootprintMiB':stats([v['memoryActive']['footprintMiB'] for v in rows]),
            'activeResidentMiB':stats([v['memoryActive']['residentMiB'] for v in rows]),
            'loadAndGraphMs':stats([v['loadAndGraphMs'] for v in rows]),
            'firstMixerRenderMs':stats([v['firstMixerRenderMs'] for v in rows]),
            'cpuPercentOneCore':stats([v['cpuPercentOneCore'] for v in rows]),
            'nodes':[v['resources']['nodes'] for v in rows],
            'voices':[v['resources']['voices'] for v in rows]}
    result['capacity']=raw.get('capacity',[])
    if 'avShowControlStress' in raw:
        s=raw['avShowControlStress']
        result['stress']={k:v for k,v in s.items() if k!='mixerCommandMs'}
        result['stress']['mixerCommandMs']=stats(s['mixerCommandMs'])
        result['finalResources']=raw['finalResources']
    return result
if __name__=='__main__':
    print(json.dumps(summarize(sys.argv[1]),indent=2))
