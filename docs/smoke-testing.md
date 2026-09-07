# Simulator smoke procedure

Use Xcode MCP to build/run/stop the app and inspect its debugger/console. Use
the RocketSim skill and CLI for simulator interactions. These checks establish
behavior, not physical-device performance. See [validation.md](validation.md)
for the recorded results and remaining performance work.

## Start and preserve the environment

1. Open `Sekai/Sekai.xcodeproj` through Xcode MCP, select the Sekai scheme and a
   simulator, and run with the debugger attached. Keep the same simulator UDID
   and app installation through the restart check.
2. Resolve RocketSim with `command -v rocketsim`, open RocketSim, and compare
   `rocketsim simulator focused` with Xcode's destination. The September 5 run
   used `/opt/homebrew/bin/rocketsim`, iPhone 17 Pro, iOS 26.5.
3. Run the backend with timestamped output, using an unused port or
   ensuring no other server owns 8787. Configure `SEKAI_BASE_URL` if necessary:

   ```bash
   python3 scripts/record_mock.py --fail-rate 1.0 > /tmp/sekai-failure.log
   ```

   Leave the default payload and latency intact. The wrapper forces the server
   to bind to `0.0.0.0`, timestamps the child process's output, and does not
   intercept or modify responses.
   Timestamps describe when stdout was received. The mock logs responses, not
   request starts, so retry intervals include response latency. Stop with Ctrl+C.
4. Inspect existing hidden state and choose visible report/block targets.
   Do not erase the installation merely to make fixed example IDs available.
   Record IDs rather than titles: titles repeat in this mock.

## Drive playback and lifecycle with RocketSim

Read the screen before choosing selectors or gesture coordinates:

```bash
rocketsim elements --agent --agent-mode act
rocketsim screenshot > /tmp/sekai-before.png
```

On the recorded 402 × 874-point portrait device, these coordinates lie inside
the observed feed. Reinspect the screenshot before using them on another device:

```bash
rocketsim do \
  --step "interact swipe --from '200,650' --to '200,250'" \
  --step "interact swipe --from '200,250' --to '200,650'"

rocketsim do \
  --step "interact swipe --from '200,720' --to '200,180' --duration 0.1" \
  --step "interact swipe --from '200,720' --to '200,180' --duration 0.1" \
  --step "interact swipe --from '200,720' --to '200,180' --duration 0.1" \
  --step "interact swipe --from '200,180' --to '200,720' --duration 0.1"
```

Confirm the final item reaches PLAYING using a screenshot or the DOM probe
below. In Xcode logs, verify every new play follows the previous pause and that
only three WebView creation events exist per process. Capture the entire
filtered log (`tailLimit` large enough and `truncated: false`), using a pattern
such as `Created WebView|Load game|Paused |Play completion|Memory warning|Canceled load`.

Open the current creator using its observed button label. Verify pause, dwell
on Profile, then use `Done` and verify only the current item resumes. For
backgrounding, start from a visibly playing item:

```bash
rocketsim interact button home
rocketsim elements --agent --agent-mode act
rocketsim interact activate --label Sekai --type button --screen latest
```

Use a fresh Home snapshot before activating Sekai. A coordinate-backed Home
icon tap selected a neighboring app in the recorded session; AX activation
worked. RocketSim deltas and WebKit accessibility content were sometimes stale,
so confirm the resulting screen and inspect native logs/DOM for playback.

## Read all three WebKit documents

The following commands run through Xcode MCP `InvokeDebuggerCommand` and do not
change application playback state. Check `process status`, then `process interrupt`.
Find the current FeedViewController address:

```text
expr -l objc++ -O -- [[[UIApplication sharedApplication] keyWindow].rootViewController _printHierarchy]
```

Replace `FEED_ADDRESS` with the live address from that output. Do not reuse it
after process restart. Swift reflection avoids importing internal app types:

```text
expr -l Swift -- import Foundation
expr -l Swift -- let $feedObject = unsafeBitCast(UInt(FEED_ADDRESS), to: NSObject.self)
expr -l Swift -O -- Mirror(reflecting: $feedObject).descendant("pool", "slots")
expr -l Swift -- import WebKit
expr -l Swift -- for index in 0..<3 { (Mirror(reflecting: $feedObject).descendant("pool", "slots", index, "webView") as! WKWebView).evaluateJavaScript("JSON.stringify({id:location.pathname,playing:window.playing,frames:window.frames,status:document.getElementById('state')?.textContent})") { value, error in print("SMOKE_JS PROFILE_A slot=\(index) value=\(String(describing: value)) error=\(String(describing: error))") } }
continue
```

Read `SMOKE_JS` from Xcode console after resuming so async callbacks can finish.
Change the stage label for each sample. Sample the settled Feed, Profile twice
with time spent running between samples, and Feed after return. Require exactly
one current playing document in Feed, no playing documents in Profile, stable
off-screen frame counters, and no probe errors. The properties being read are
specific to the provided mock. Do not call play/pause from the probe.

## Failure, retry, and durable restart

Use the observed Content actions → Report content → Spam controls. Verify that
the item disappears, confirmation and sync-failure feedback appear, and the
item remains hidden while both immediate and delayed requests fail. Count two
report response lines, then observe at least two additional retry-delay periods
without new requests. Background/foreground once; require exactly two more
responses, followed by another dormant period. Do not create more moderation
actions during this interval.

Next, open a visible creator's Profile → top-right Creator actions → Block.
Verify all works disappear and Feed chooses a survivor. Verify the block request
also receives one delayed retry. Stop the app with Xcode MCP, then Run on the
same simulator without uninstalling. Traverse the previously hidden positions,
cross a feed pagination boundary, and reverse-scroll. Compare raw item IDs in
the mock with loaded/visible IDs. Hidden IDs must not be loaded or shown, and
no pending moderation requests should be reconstructed after restart.

Read the actual state file through the stopped Xcode debugger before and after
restart, then resume:

```text
expr -l objc++ -O -- [NSString stringWithContentsOfURL:[(NSURL *)[[[NSFileManager defaultManager] URLsForDirectory:14 inDomains:1] firstObject] URLByAppendingPathComponent:@"moderation.json"] encoding:4 error:nil]
```

## Simulate the memory-warning notification

Pause in the debugger and find the live FeedViewController address as above.
Read the collection's prefetch state, post the standard notification, and read
again. This is notification-handler coverage, not actual memory pressure:

```text
expr -l objc++ -- (BOOL)[(UICollectionView *)[[(UIViewController *)FEED_ADDRESS view].subviews firstObject] isPrefetchingEnabled]
expr -l objc++ -- (void)[[NSNotificationCenter defaultCenter] postNotificationName:(id)UIApplicationDidReceiveMemoryWarningNotification object:[UIApplication sharedApplication]]
expr -l objc++ -- (BOOL)[(UICollectionView *)[[(UIViewController *)FEED_ADDRESS view].subviews firstObject] isPrefetchingEnabled]
continue
```

Require YES → NO and the pool's memory-warning log. Swipe to multiple new items
with RocketSim. Require only current-item loads, current-item playback after
readiness, and no extra creation events. Recheck after a moderation replacement.

## Check the saved September 5 evidence

```bash
python3 scripts/check_smoke_evidence.py
```

This command validates the saved scenario's event ordering, creation counts,
memory-warning load sequence, retry response counts/intervals, restart filtering,
and staged DOM samples. It does not run UI automation or generalize fixed IDs to
another installation. Use new evidence filenames and update scenario-specific
expectations for a new run; never overwrite old evidence to turn a failure into
a pass. Preserve screenshots, full filtered Xcode logs, backend arguments, and
the actual outcomes in validation.md. Stop task-owned mock/debug processes when
finished.
