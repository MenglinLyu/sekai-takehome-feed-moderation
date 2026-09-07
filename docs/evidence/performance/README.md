# Local performance results

Only the latest capture, **20260906-191821-565605**, is retained here for Git
version control. See the [analysis](20260906-191821-565605/report.md) for the
workload, environment, observed WebKit attachment stall, and measurement limits.

The README asks for frame-timing numbers, changes made because of them, and
memory use while scrolling approximately 5 MB items. In trace window `[10, 40)`,
the capture recorded **44.667 display presentations/s**, including idle/loading
periods, and **one 258.377 ms application hitch**. Feed gestures cover 8.973 s of
that window. Memory and build/source provenance were not verified.

## Retained evidence

All paths below are relative to `20260906-191821-565605/`.

| Files | Contents |
| --- | --- |
| `report.md` | Findings, stack analysis, limitations, and retest work. |
| `summary.json`, `fps.csv` | Frame and hitch measurements. |
| `fps.xml`, `hitches.xml` | Original exports used to recompute those measurements. |
| `feed-signposts.csv`, `analysis/intervals.csv` | Feed events and paired phase intervals. |
| `analysis/summary.json` | Phase statistics, gesture coverage, and relevant sampled wait stacks. |
| `analysis/context.xml`, `analysis/display-info.xml`, `toc.xml` | Hang/thermal events, display information, and trace metadata. |
| `metadata.json`, `record.log`, `mock.log` | Capture configuration, lifecycle, and server requests. |

Recompute the frame summary without a device or Instruments:

```sh
python3 scripts/summarize_xctrace.py \
  docs/evidence/performance/20260906-191821-565605 --start 10 --end 40
```

The original `.trace`, raw signpost XML, and large context-switch stack export
remain local under `docs/artifacts/recordings/20260906-191821-565605/`, which is
ignored by Git. Regenerating the phase analysis requires that local stack export;
the relevant extracted stacks are included in `analysis/summary.json`.

For a new capture, run the [recording and analysis procedure](../../performance.md),
copy the compact files listed above into a new run directory here, and update the
README and validation links. Replace the previously retained run so this directory
continues to contain only the latest result and its analysis.
