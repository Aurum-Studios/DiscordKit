# Isolated Linux compilation runner evidence

## GitHub configuration

GitHub acknowledged the following configuration on November 8, 2026. An
independent API read at 17:50:43 UTC verified:

- Repository: `Aurum-Studios/DiscordKit`, ID `1421497969`, public.
- Runner group: `DiscordKit-Native`, ID `8`, selected-repository visibility,
  public repositories allowed, with DiscordKit as its only selected repository.
- GitHub-hosted runner: `linux-x64-4`, ID `23`, group `8`, status `Ready`.
- Image: GitHub Ubuntu 24.04 x64, image ID `2295`.
- Machine: `4-core`, 4 CPUs, 16 GiB RAM, 150 GB disk.
- Maximum runners: `1`. Static public IP allocation: disabled.
- Pre-existing MiniCarson runner configurations, groups and selected repository
  access matched the preflight snapshot after provisioning.

Nonsecret request intents, acknowledgments, preflight inventory and the verified
configuration are retained locally under `.build/runner-setup`. These ignored
receipts contain no authentication token. Provisioning used the authenticated
operator's existing GitHub CLI session.

## Repository validation

- `python3 -m unittest discover -s Tools/ci -p 'test_linux_ci.py'`: 20 tests
  passed, including compiler-limit propagation, committed dependency pins and
  process cleanup.
- Actionlint 1.7.12: `actionlint -shellcheck='' .github/workflows/ci.yml` passed
  with the exact custom label registered in `.github/actionlint.yaml`.
  ShellCheck was unavailable and was not run.
- Parsed YAML comparison against base
  `1b8ea36db05be06189829c5a6f20a13d1656630b` confirmed the original macOS steps,
  auxiliary jobs, workflow controls, timeout, shell and environment were
  preserved. Linux retains its original steps and order, with Linux-only guards
  simplified and all eight helper invocations explicitly selecting four jobs.
- `git diff --check` passed.
- Independent agent review found no issues with the workflow, runner routing,
  configuration registry or documentation.

## Qualification boundary

The Linux job now selects both `DiscordKit-Native` and `linux-x64-4` in the local
workflow. Its helper retains the two-job local default; CI passes `--jobs 4`.
The change is committed locally and has not been pushed or dispatched. No hosted
compilation, timing, runner utilization or successful certification is claimed.
Review the exact committed workflow's Linux host logs and completed stages after
publication before treating the new runner as compilation-qualified.
