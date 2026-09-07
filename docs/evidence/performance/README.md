# Local performance results

The latest capture is **20260906-203252-734998**. Read the
[latest perf report](20260906-203252-734998/report.md) for the permanent-canvas
retest and remaining issues. The [baseline](20260906-191821-565605/report.md)
is also retained so the before/after comparison can be audited.

The README asks for frame-timing numbers, changes made because of them, and
memory use while scrolling approximately 5 MB items. In trace window `[10, 40)`,
the latest capture recorded **58.867 display presentations/s**, including idle/loading
periods, and **zero application hitches**, compared with one 258.377 ms baseline
hitch. Observed Feed gestures cover 8.598 s of that window; early markers are missing.
The full trace still has one 16.670 ms hitch and 54.313/57.770 ms potential
interaction delays. The original attachment wait did not recur, but content
loading remains unresolved. Memory and build/source provenance were not verified.

## Retained evidence

All paths below are relative to each retained run directory.

| Files | Contents |
| --- | --- |
| `report.md` | Findings, stack analysis, limitations, and retest work. |
| `summary.json`, `fps.csv` | Frame and hitch measurements. |
| `fps.xml`, `hitches.xml` | Original exports used to recompute those measurements. |
| `feed-signposts.csv`, `analysis/intervals.csv` | Feed events and paired phase intervals. |
| `analysis/summary.json` | Phase statistics, gesture coverage, and relevant sampled wait stacks; the latest run adds representative non-WebKit delay stacks and signpost range. |
| `analysis/context.xml`, `analysis/display-info.xml`, `toc.xml` | Hang/thermal events, display information, and trace metadata. |
| `metadata.json`, `record.log`, `mock.log` | Capture configuration, lifecycle, and server requests. |

Recompute the frame summary without a device or Instruments:

```sh
python3 scripts/summarize_xctrace.py \
  docs/evidence/performance/20260906-203252-734998 --start 10 --end 40
```

The original `.trace`, raw signpost XML, and large context-switch stack export
remain local under `docs/artifacts/recordings/RUN/`, which is
ignored by Git. Regenerating the phase analysis requires that local stack export;
the relevant extracted stacks are included in `analysis/summary.json`.

For a new capture, run the [recording and analysis procedure](../../performance.md),
copy the compact files listed above into a new run directory here, and update the
README and validation links. Keep the comparison baseline alongside the latest
result when a report uses it to assess an optimization; leave large raw traces
and stack exports in the ignored artifacts directory.
