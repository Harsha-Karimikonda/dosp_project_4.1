# Project 4, Part I: Reddit engine and simulator

A **pure Erlang/OTP** Reddit engine, multi-process client simulator, benchmark runner, PDF report generator, and submission packager. No external dependencies, Python, Gleam, REST server, or web client.

| Member | Email | UFID |
| --- | --- | --- |
| Harsha Karimikonda | hkarimkonda@ufl.edu | 50966091 |
| Venkatesh Gollepalli | ve.gollepalli@ufl.edu | 24690032 |

## Setup and run

Install **Erlang/OTP 27 or newer**, including the compiler, EUnit, and development headers. Tested with OTP **29.1.2**, on macOS arm64. For example:

```sh
# macOS with Homebrew
brew install erlang

# Ubuntu/Debian: check that your distribution supplies OTP 27+
sudo apt-get install erlang-base erlang-dev erlang-eunit erlang-tools
```

Check `erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'`. The compiler, EUnit, `peer`, `json`, and `zip` are supplied by OTP; no Rebar or package downloads are needed. OTP 27+ is required for the built-in JSON module.

Run these commands from this directory:

```sh
escript scripts/project4.escript build
escript scripts/project4.escript test
escript scripts/project4.escript demo
escript scripts/project4.escript simulate --users 1000
```

The escript compiles sources and tests into `build/ebin` with warnings treated as errors before every command. `test` runs EUnit. `demo` checks the features across independent engine/tester OS processes, concurrent vote consistency, offline delivery, request timeout, and an unavailable engine OS process.

Simulation and benchmark commands open **loopback** network ports for Erlang distribution and EPMD. Run in an environment permitting local networking. Peer nodes bind distribution to `127.0.0.1`, share a run-specific cookie, and are stopped on exit. The EPMD service may remain available after a run.

## Benchmarks and evidence

```sh
# Single configurable run: separate engine and two client OS processes
escript scripts/project4.escript simulate \
  --users 10000 --workers 2 --communities 100 \
  --warmup 10 --duration 30 --seed 42 --interval 1000 \
  --schedulers 2 --output results/custom-run

# Three repeats at 100, 1000, 10000; then probes at 20000 and 50000
escript scripts/project4.escript benchmark \
  --budget 900 --output results/new-sweep
```

Use a **new output directory** each time. The runner rejects existing directories to preserve evidence. Times are integer seconds; `interval` is milliseconds. Populations, durations, intervals, scheduler counts, and worker counts must be positive; warmup can be zero. The number of workers cannot exceed the user population.

The default sweep uses seeds 42, 43, and 44 and a roughly 15-minute wall-clock budget. It checks the remaining budget before launching each run; setup, peer startup, failure cleanup, or an unusually slow run can exceed that budget. Larger populations stop after a run failure or an SLO failure. The SLO is at least 99% successful observed completions, less than 1% timeouts, p95 below one second, and no sustained mailbox growth (six strictly increasing one-second samples ending above 100). This is an explicit local experiment criterion, not a production guarantee.

If a sweep is interrupted, preserve completed runs and continue with:

```sh
escript scripts/project4.escript benchmark --resume --output results/new-sweep
```

Resume skips completed population/seed pairs, preserves incomplete run directories under `build/interrupted`, and measures elapsed budget from the earliest retained resource sample. Interruption time therefore counts toward the budget. If you deliberately want a larger total budget, pass `--budget` explicitly.

Each run saves:

- `initial.json` and `final.json`: engine counts, memberships, online accounts, reposts, and per-community post counts.
- `workerN-metrics.json`: offered request counts, outcome/operation latency histograms, window start, duration, and exact maximum observed latency.
- `engine-resources.jsonl` and `workerN-resources.jsonl`: one-second CPU, BEAM memory, process-count, and mailbox samples.
- `summary.json`: offered and successful throughput, p50/p95/p99 bounds, error/timeout rates, per-operation numbers, resources, Zipf checks, and posting correlation.

The sweep adds `results.json` (all completed summaries) and `sweep.json` (largest tested/passing populations, stop reason, elapsed time, failures). The supplied final evidence is under `results/erlang-benchmark`.

### Measured results supplied with this submission

These are actual local measurements from the 11-run sweep, with two schedulers per node:

| Users | Repeats | Median successful requests/s | Worst p95 upper bound | SLO |
| ---: | ---: | ---: | ---: | --- |
| 100 | 3 | 93.0 | 2 ms | Pass |
| 1,000 | 3 | 925.6 | 4 ms | Pass |
| 10,000 | 3 | 9,224.3 | 64 ms | Pass |
| 20,000 | 1 | 18,526.4 | 64 ms | Pass |
| 50,000 | 1 | 23,113.1 | 4,096 ms | Fail: latency |

All observed measured completions succeeded; there were no recorded errors or timeouts. At 50,000 users, the engine mailbox peaked at 42,248 requests, consistent with queueing at the single state server. The sweep took 562 seconds, including the interruption and resume, within its 900-second budget. **20,000 is the largest tested population meeting the chosen SLO; 50,000 is the largest tested population.** Neither is an absolute capacity claim. See the report and raw per-run JSON for variability, operation breakdowns, memory, CPU, and load-generation limits.

### Measurement interpretation

Setup is excluded. Users run during warmup, but request measurements start afterward. Offered requests are counted at request start; completed requests at response time. Calls crossing window boundaries can make the totals differ. Percentiles use power-of-two millisecond buckets and are **upper bounds**; the first bucket includes 0–1 ms.

Resource summaries use samples inside the measurement window. Memory is BEAM allocated memory, not OS RSS. CPU is cumulative runtime CPU between the first and last in-window samples; divide CPU milliseconds by elapsed milliseconds for utilization relative to one core. One-second sampling can miss short spikes. Per-community posting differences and repost totals cover **warmup plus measurement**, as documented in each summary.

This is a **closed-loop** load generator: online users wait for a response and then sleep for the configured interval. Offline periods and higher latency reduce offered load. A population count is not a simultaneous request count or proof of maximum engine capacity.

## Features and interfaces

`reddit_server:request(EngineNodeOrPid, UserBinary, Operation, TimeoutMs)` returns `{ok, Value}` or `{error, Reason}`. The local application registers `reddit_server`; remote calls address `{reddit_server, EngineNode}`. Expected errors include `duplicate`, `invalid`, `not_found`, `forbidden`, `offline`, `timeout`, and `unavailable`. OTP call references correlate replies, and timed-out mutations are never automatically retried.

| Operation | Successful value | Behavior |
| --- | --- | --- |
| `{register, Name}` | `done` | Unique nonempty account name; initially online |
| `{create, Community}` | `done` | Unique community; creator joins |
| `{join, Community}` / `{leave, Community}` | `done` | Idempotent membership updates |
| `{post, Community, Text, OriginalIdOrNone}` | `{created, Id}` | Text post or repost; membership required |
| `{comment, PostId, ParentCommentIdOrNone, Text}` | `{created, Id}` | Arbitrary nesting; parent must belong to same post |
| `{vote, {post, Id}, Direction}` | `{score, Score}` | Direction `-1`, `0`, `1`; one vote per user/target |
| `{vote, {comment, Id}, Direction}` | `{score, Score}` | Same vote rules for comments |
| `{karma, Account}` | `{score, Karma}` | Sum of received post/comment vote deltas |
| `{feed, BeforeIdOrNone, Limit}` | `{posts, [PostMap]}` | Joined communities, descending IDs, exclusive cursor |
| `{thread, PostId}` | `{comments, [CommentMap]}` | Creation order with parent IDs to reconstruct tree |
| `{send_message, Recipient, Text}` | `{created, Id}` | Recipient inbox; works while recipient is offline |
| `{reply_message, MessageId, Text}` | `{created, Id}` | Recipient replies to sender, linked to previous message |
| `{inbox, BeforeIdOrNone, Limit}` | `{messages, [MessageMap]}` | Caller’s received messages only |
| `{online, Boolean}` | `done` | Preserve content, subscriptions, and inbox across reconnect |
| `inspect` | `StatsMap` | Simulator diagnostics; not an end-user operation |

`none` is an atom. Names and text are UTF-8 binaries. Text is nonempty after trimming and at most 10,000 bytes. Feed/inbox limits are 1–100. Self-votes are rejected. New content starts at zero score. Setting a vote to zero removes its score contribution; repeating a vote has no additional effect. Karma changes correctly when votes change direction. New global content IDs provide a deterministic chronological order. Reposts have their own author and score and preserve the source ID.

Account identity is passed explicitly by trusted simulator clients; this Part I engine does not implement passwords or production authentication. Inbox privacy and reply permissions are enforced against that supplied identity.

## Architecture and workload

`reddit_app` starts `reddit_sup`, which supervises the authoritative `reddit_server` gen_server. `reddit_engine` performs pure state transitions over indexed maps. The single server makes operations atomic, including vote/karma changes. It can become the throughput bottleneck. The controller verifies its PID did not change during a benchmark; an engine restart invalidates the run.

The OTP `peer` controller launches **one engine OS process and multiple client OS processes**. Each client node has one Erlang process per assigned user, a coordinator, and a metrics collector. Actor concurrency alone inside one VM is not used as a substitute for the required process separation. Small controller RPC processes handle setup, readiness, and snapshots; measured activities use direct distributed `gen_server` requests.

For rank `r`, community membership is exactly `max(1, floor(N / r^1.1))` simulated users, selected without duplicates by a rank-specific cyclic permutation. A seed account adds one member to each community. Rank 1 includes every user. Requests choose among each user’s joined communities, which makes larger communities receive more posts. The member/post-count correlation is reported rather than assumed.

Online intervals last 5–15 seconds and offline intervals 2–5 seconds. Disconnection is per simulated user at the application level; a worker node remains connected to serve its other users. Offline users issue no activity requests. A request that changes connection state is counted separately.

Default activity choices: 30% feed, 25% posting, 20% commenting, 15% voting, 5% messaging, and 5% membership changes. Each membership action issues both leave and join. Ten percent of posting actions are reposts. Half of comments target earlier comments; per-community cached parents allow deep chains. Messaging includes sends, inbox reads and replies. Votes target seed-authored content to avoid generating intentional self-vote failures. Setup seeds valid content and incoming messages for every user. PRNG seeds reproduce choices, not concurrency ordering or timing.

## Report and submission

```sh
# Generate from an actually completed sweep
escript scripts/project4.escript report --input results/erlang-benchmark

# Generates project4.zip; deliberately excludes report.pdf and build/runtime files
escript scripts/project4.escript package
```

The report generator uses OTP JSON and writes the PDF directly in Erlang, with no third-party PDF tools. Team details live in `config/members.config` and are already populated for both members.

Submit **`project4.zip` and `report.pdf` as separate attachments**. Paste `SUBMISSION_COMMENT.txt` into the submission comment to include both members. The ZIP contains source, EUnit tests, the Erlang escript, team configuration, run instructions, and benchmark evidence. It excludes PDFs, the local toolchain, build outputs, and temporary development artifacts.

## Limits and references

This is an in-memory Part I engine. A restart loses state; durable storage, authentication, REST/WebSockets, browser clients, images, and Markdown are outside the assignment scope. The benchmark is local loopback with fixed text sizes and short windows. Larger user populations need more memory; two schedulers per node limit oversubscription. Results do not establish an absolute maximum or performance over a real network.

The assignment’s “accounts with a lot of subscribers” is interpreted as popular subreddits receiving more posting activity. The requested member-count Zipf distribution is explicitly measured.

References: [assignment’s Reddit API overview](https://www.reddit.com/dev/api/), [OTP gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html), [OTP peer](https://www.erlang.org/doc/apps/stdlib/peer.html), and [Distributed Erlang](https://www.erlang.org/doc/system/distributed.html).
