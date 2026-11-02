# VEP Audit Report
Generated: 2026-11-02T20:55:24.237532

## Source Provenance
- Input VEP: 36334863 bytes
- VEP SHA256: 5d8b7ec0f657649676b8af33d544498a2a4a4a2815ac0e27750af588cf239938
- Generator: make_v3b.ps1 (binary container patcher, PowerShell)
- Output audited: test13m.mp4 (from 1-Engineering-Overview-Standard-Playable-FINAL.mp4)
- Output size: 36334062 bytes

## Observed Facts (direct observation)
1. Container: probe.json shows format/streams
2. Actual decoded frames: 11609
3. Audio decode: exit code recorded in track_info.json
4. Subtitle streams: 0 found
5. Frame pixel statistics: signalstats.txt
6. Sample PNGs: frame_0 through frame_4 at 0-100%

## Tool-Derived Results
1. Frame count from framemd5: 11609
2. Duplicate frames: 2
3. Y channel stats: see signalstats.txt for per-frame YMIN/YMAX/YAVG

## Unverified Observations (not confirmed as algorithm facts)
1. Purple coloration - observed by user in multiple playback tests
2. Previous claims of "only first 8 bytes encrypted" - based on single sample0 observation
   CANNOT be generalized to all samples without further evidence
3. VMEM capture of 703 frames showed "correct color" per user confirmation of one
   23-second AVI sample. This does NOT verify all 11,687 frames would be correct.

## Frame Count Discrepancy (703 vs 11,687)
- Declaration: 11,687 in moov stsz (full 389.6s at 30fps)
- VMEM capture: 703 (~23.4 seconds) before worker premature exit
- This audit decode: 11609
- Explanation: vmem worker crashed/stopped after ~23s due to rate/join bugs.
  Full explanation in frame_count_analysis.json

## Known Generation Pipeline Issues
1. make_v3b.ps1 does not verify output correctness after patching
2. Container patch only fixes stss/SEI-header/stsd, does NOT modify video payload
3. Video payload remains original encrypted bytes from VEP's mdat
4. Standard decoder receives encrypted CABAC data -> produces visual artifacts

## Completion Criteria Status (per user's 6-point standard)
1. Standard tools identify output: PASS (ffmpeg can open and decode)
2. Video decodes start-to-finish: UNKNOWN (11609/11687 frames)
3. Audio decodes: UNKNOWN - see track_info.json
4. AV sync: UNKNOWN (not tested in this audit)
5. Duration/framerate/content match: CHECK - probe.json shows actual values
6. Multi-sample repeatability: NOT TESTED (only one VEP file available)

Audit complete. All raw data preserved in this directory.
