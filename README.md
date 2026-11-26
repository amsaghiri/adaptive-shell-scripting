# Adaptive Shell Scripting with Quine Programs and Large Language Models

A shell script that repairs itself. The script watches its own runs, and when it starts failing because
the environment changed, it asks a large language model for a corrected version of its working part,
checks the proposal in three independent validation stages, and replaces itself atomically.

This repository is a reference implementation of the framework described in:

> A. M. Saghiri, "Adaptive Shell Scripting with Quine Programs and Large Language Models,"
> *2026 International Conference on Current Research in Artificial Intelligence and Data Science
> (ICCRAIDS)*, 2026, pp. 1–7. doi: [10.1109/ICCRAIDS67816.2026.11519702](https://doi.org/10.1109/ICCRAIDS67816.2026.11519702)

**About this code.** It was written after the paper, from the paper's description of the architecture,
and it implements each component the paper defines. The figures in
[Results reported in the paper](#results-reported-in-the-paper) are the paper's own; this repository
does not regenerate them. What the code here does is covered by the test suite in `tests/`.

## The idea

Operations scripts are static. When a directory moves, a permission changes, or a service slows down,
the script keeps failing until a person notices, diagnoses the problem, edits the script, tests it, and
deploys it. The framework closes that loop automatically, under explicit safety constraints.

The script is split into two parts, and only one of them may ever change:

| Part | Role |
| --- | --- |
| **Quine core** (immutable) | Reads its own source, runs the payload, records observations, decides when to adapt, and performs the replacement. Protected by a SHA-256 checksum and read-only permissions. |
| **Evolvable payload** | The lines between `# PAYLOAD-BEGIN` and `# PAYLOAD-END`. This is the actual job (a backup, a health check) and the only region the LLM may rewrite. |

Formally the system is a tuple (S, O, T, V, Φ) with state S = (C, P, M): the immutable core C, the
evolvable payload P, and metadata M. O is the observation log, T the LLM transformation that proposes
a new payload, V the validator, and Φ the atomic commit.

## The adaptation loop

1. **Execute** the payload.
2. **Observe**: append a structured record of the run (status, exit code, duration, error text, and peak memory when GNU `time` is installed).
3. **Trigger**: check whether any adaptation trigger has fired.
4. **Propose**: send the payload and recent observations to the LLM and receive a candidate payload.
5. **Validate**: run the candidate through the three-stage safety pipeline.
6. **Commit**: replace the script atomically, keeping a backup for rollback.

## Components

| Component | File | What it does |
| --- | --- | --- |
| Quine core | `adaptive.sh`, `lib/common.sh` | Self-reading, payload extraction, core checksum, sealing and verification. |
| Evolvable payload | end of `adaptive.sh` | Bounded by the two markers. |
| Observation layer | `lib/observe.sh` | One JSON line per run in `state/observations.jsonl`. Error text is sanitized. |
| Triggers | `lib/triggers.sh` | The four OR-combined triggers below. |
| LLM integration | `lib/propose.sh`, `llm/` | Isolated prompt template, temperature 0.3, 2000-token budget. |
| Safety pipeline | `lib/validate.sh`, `policy/` | Three fail-fast stages, independent of the LLM. |
| Atomic commit | `lib/commit.sh` | Backup, SHA-256, temporary file, integrity check, atomic rename, rollback. |

### Triggers

Any one is enough.

| Trigger | Fires when | Setting |
| --- | --- | --- |
| Consecutive failures | 3 runs in a row fail | `ASS_CONSECUTIVE_FAILURES` |
| Failure rate | 50% of the last 10 runs fail | `ASS_WINDOW`, `ASS_WINDOW_FAILURE_RATE` |
| Error pattern | the last error matches a regex for a missing resource, permission denied, or connection refused | `ASS_ERROR_REGEX` |
| Performance degradation | a run takes more than 2× the mean of the last 20 successful runs | `ASS_SLOWDOWN_FACTOR`, `ASS_BASELINE_RUNS` |

### Safety pipeline

| Stage | Checks |
| --- | --- |
| 1. Syntactic | `bash -n`, ShellCheck, and marker verification (exactly one pair of markers in the assembled script). |
| 2. Semantic | A sandboxed Docker run with mock data, no network, and a 60-second timeout. |
| 3. Policy | Command whitelist, path restrictions, and forbidden patterns (`policy/`). |

A candidate that fails any stage is discarded, the running script is left untouched, and the case is
written to `state/needs_attention` for a person to handle.

## Quick start

Requirements: Bash 4+, `jq`, `sha256sum`, `timeout`, and ShellCheck. Docker is needed for the sandbox
stage in real use; the demo and the tests do not need it.

```bash
# The adaptive-backup use case, end to end, in a temporary directory
bash demo/backup_demo.sh

# The test suite (31 checks: every trigger, every validation stage, commit, rollback)
bash tests/run_tests.sh
```

Both run offline. They replace the LLM with `llm/mock.sh`, which returns a prepared reply, and use the
`local` sandbox mode.

The demo shows a backup script whose source directory is moved. Three scheduled runs fail, the third
triggers adaptation, the proposed payload passes validation and is committed, and the next run succeeds:

```
== 4. Three scheduled runs fail; the third one triggers adaptation
   source directory <workdir>/data/projects is missing
   source directory <workdir>/data/projects is missing
   source directory <workdir>/data/projects is missing
   [adaptive] adaptation started (trigger: consecutive_failures)
   [adaptive] candidate passed all three validation stages
   [adaptive] adaptation committed (version 2)

== 5. The next scheduled run uses the adapted payload
   backup of <workdir>/data/projects-2026 written to <workdir>/backups
```

## Using it on a real script

```bash
cp config.env.example config.env        # set the LLM endpoint, key, and model
./adaptive.sh seal                      # record the core checksum, once
./adaptive.sh install examples/backup/payload.sh
./adaptive.sh run                       # this is the command to schedule
```

Schedule `adaptive.sh run` with cron. The paper's testbed invoked the script every 4 hours:

```
0 */4 * * *  /opt/adaptive-shell-scripting/adaptive.sh run
```

Other commands: `status`, `payload`, `verify`, `adapt [reason]`, and `rollback`.

**The LLM** is reached through `ASS_LLM_CMD`, any command that reads the prompt on standard input and
prints the new payload. `llm/openai_compatible.sh` works with any OpenAI-compatible chat completions
endpoint over HTTPS. No model is set by default; choose one in `config.env`.

**Edit `policy/` for your site** before use: `allowed_commands.txt`, `allowed_paths.txt`, and
`forbidden_patterns.txt` define what a payload may do.

**Mock data for the sandbox**: point `ASS_SANDBOX_SETUP` at a script that creates the files the payload
expects, as in `examples/backup/sandbox_setup.sh`.

## Use cases

- `examples/backup/` – adaptive backup. A moved directory causes consecutive failures; the fix is a path
  update with existence checks.
- `examples/monitoring/` – adaptive monitoring. A `LOAD_THRESHOLD` that no longer fits the host is
  adjusted to reduce alert noise.

## Results reported in the paper

Testbed: 10 Ubuntu 22.04 virtual machines, NFS 4.1, Prometheus and Grafana, 30 days, 12 environmental
changes, script invoked every 4 hours.

| Measure | Reported value |
| --- | --- |
| Adaptation success | 94.1% (16 of 17) |
| Candidates rejected by validation | 4 of 17 (3 at the syntactic stage, 1 at the semantic stage) |
| Error rate after adaptation | 1.8% |
| Time to adapt | about 12 h adaptive, against 44.6 ± 15.2 h for the manual baseline (3.7×) |
| Runs needing manual intervention | 27.3%, a 73% reduction |
| Cost per adaptation | $0.45–1.20, against $150–225 manual |
| Pipeline latency | 3–5 s |
| Adaptive backup use case | 7 of 8 adaptations succeeded (87.5%) |

The time comparison comes from a Monte Carlo simulation (120,000 samples, seed 42); the manual baseline
is simulated, not measured.

Detection time depends on how often the script runs and how many failures are required:

| Invocation interval | Failures required | Time to adaptation |
| --- | --- | --- |
| 4 h | 3 | about 12 h |
| 2 h | 2 | about 4 h |
| 1 h | 1 | about 1 h |

### Limitations stated in the paper

- The scope is a single script; coordination across scripts is future work.
- The manual baseline is simulated.
- The LLM is an external dependency, and local models were not tested.
- The evaluation is small: 10 virtual machines and 12 changes.

## Implementation notes

Points where this code makes a choice the paper leaves open, or goes no further than the paper:

- **Local sandbox mode** (`ASS_SANDBOX=local`) runs the candidate as a subprocess with a time limit and
  no isolation. It exists for the tests and the demo. In this mode the policy stage runs before the
  semantic stage, so that nothing is executed before it has passed the whitelist. Use `docker` otherwise.
- **The policy stage is textual.** It extracts command words and paths with pattern matching, not a
  shell parser, and rejects when unsure. Valid payloads that use unusual quoting can be rejected.
- **The error-pattern trigger acts on a single failure.** With the default regex, a missing directory
  triggers adaptation on the first failed run. The demo switches this trigger off (`ASS_ERROR_REGEX=""`)
  to show the three-consecutive-failures path of the backup use case.
- **The performance trigger** needs at least 5 earlier successful runs before it can fire
  (`ASS_BASELINE_MIN_RUNS`).
- **After a rejected proposal** the script waits 3 runs before asking again (`ASS_COOLDOWN_RUNS`).
- **Triggers look only at runs since the last commit**, so failures an adaptation already answered do
  not fire again.
- **Signed logs** (HMAC) are recommended by the paper and are not implemented here.
- **Not exercised by the tests:** the Docker sandbox path and `llm/openai_compatible.sh` against a live
  endpoint.

## Future work named in the paper

Multi-script coordination, formal verification with symbolic execution and SMT solvers, extension to
Python and PowerShell, infrastructure-as-code targets (Terraform, CloudFormation, Kubernetes), and
meta-learning from adaptation history.

## Related work by the author

A. M. Saghiri and N. Wang, "Self-Evolving Programs: A Novel Approach Leveraging LLMs and Quine
Programs," *2024 International Conference on Computing, Internet of Things and Microwave Systems
(ICCIMS)*, 2024. doi: [10.1109/ICCIMS61672.2024.10690672](https://doi.org/10.1109/ICCIMS61672.2024.10690672)

That paper introduces the general self-evolving framework. A prototype of it, applied to a
selfish-mining defense, is in [self-evolving-programs](https://github.com/amsaghiri/self-evolving-programs).

## Citation

```bibtex
@inproceedings{saghiri2026adaptive,
  author    = {Saghiri, Ali Mohammad},
  title     = {Adaptive Shell Scripting with Quine Programs and Large Language Models},
  booktitle = {2026 International Conference on Current Research in Artificial Intelligence and Data Science (ICCRAIDS)},
  year      = {2026},
  pages     = {1--7},
  doi       = {10.1109/ICCRAIDS67816.2026.11519702}
}
```

## Author

Ali Mohammad Saghiri, Department of Computer Science, William Paterson University ·
[homepage](https://amsaghiri.github.io/) · [ACBOS Lab](https://amsaghiri.github.io/saghirilab.html)
