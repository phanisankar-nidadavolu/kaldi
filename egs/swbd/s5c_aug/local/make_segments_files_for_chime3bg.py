import os
import sys

import numpy as np

reco2dur_file = 'data/chime3background/reco2dur'
segment_file = 'data/chime3background/segmented_file'
min_seg_dur = 5  # in secs
max_seq_dur = 50 # in secs
offset = 1.0

reco2dur = {}
with open(reco2dur_file) as f:
    content = f.read().splitlines()

for line in content:
    line_parsed = line.strip().split()
    reco2dur[line_parsed[0]] = line_parsed[-1]

print('Number of recordings: {n}'.format(n=len(reco2dur)))

with open(segment_file, 'w') as fout:
    for reco in reco2dur:
        dur = float(reco2dur[reco])
        st_dur = 0.0

        while st_dur < dur:
            if dur < min_seg_dur:
                end_dur = dur
            else:
                # TODO Randomly sample a end duration
                chop_dur = np.random.randint(5, 50)
                end_dur = min(st_dur + chop_dur, dur)

            new_reco = reco + '-' + str(st_dur) + '-' + str(end_dur)

            fout.write('{n} {r} {s} {e}\n'.format(
                    n=new_reco, r=reco, s=st_dur, e=end_dur))

            st_dur = end_dur + offset
