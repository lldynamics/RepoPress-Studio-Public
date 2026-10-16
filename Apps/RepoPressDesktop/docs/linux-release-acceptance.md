# Linux release acceptance evidence (P14)

This contract records real-machine acceptance checks that hosted CI cannot honestly prove: GNOME and KDE, Wayland and X11, 1x and 2x display scale, Chinese input with IBus and Fcitx5, and the AT-SPI/screen-reader path. It is evidence, not an automated claim that CI ran those desktop sessions.

## Contract

The evidence is a JSON object with `schema: "linux-release-evidence/v1"`, a release version, one lowercase hexadecimal `artifact_sha256`, an ISO-8601 `recorded_at` with timezone, and a named `tester`. `environments` must contain exactly the five unique rows below:

This is a fixed minimum risk matrix, not a claim to test the full Cartesian product. The five exact rows are:

```text
Ubuntu 22.04 | GNOME | X11     | zh_CN.UTF-8 | 1x | IBus
Ubuntu 22.04 | GNOME | Wayland | zh_CN.UTF-8 | 2x | IBus
Ubuntu 24.04 | GNOME | Wayland | zh_CN.UTF-8 | 1x | IBus
Ubuntu 24.04 | KDE   | X11     | zh_CN.UTF-8 | 2x | Fcitx5
Ubuntu 24.04 | KDE   | Wayland | zh_CN.UTF-8 | 1x | Fcitx5
```

Each environment has the exact fields `distro`, `version`, `desktop`, `session`, `locale`, `scale`, and `ime`; exact checks `launch`, `chinese_input`, `candidate_window`, and `accessibility`; and at least one (and no more than eight) attachments. Every check must be `pass`. An attachment is an evidence file referenced by a relative path and its SHA-256; a path may occur only once across the matrix. Paths cannot be absolute, contain `..`, escape the evidence directory, or contain control characters. Unknown fields, duplicate environments, wrong distro/version/locale, pending/skip/fail results, missing matrix rows, missing files, and hash mismatches are rejected. Evidence JSON is capped at 2 MiB, each attachment at 20 MiB, and all attachments together at 100 MiB; hashes are computed with bounded streaming reads.

`accessibility` means the tester observed the app through AT-SPI and a screen reader (for example, Orca) on that exact environment. `candidate_window` means the Chinese IME candidate popup was visible and usable. Screenshots, screen recordings, terminal logs, and the tester's signed notes may be attachments; never attach secrets or personal data.

## Collection procedure

1. Build the release artifact and record its SHA-256. Keep the exact artifact unchanged.
2. On each of the five real risk-matrix environments, record the distro and version, desktop, session, locale, display scale, and IME. Set the locale to a Chinese UTF-8 locale and configure the named IME. Add at most eight unique attachments to each row.
3. Launch the artifact; exercise the primary window; type Chinese; open and select from the IME candidate window; then inspect names, roles, focus, and keyboard navigation with AT-SPI and a screen reader. Capture an attachment for the observations and calculate its SHA-256.
4. Fill the JSON contract. Use `pass` only after observing the check. Do not turn an untested or unavailable environment into `skip` or `pending`.
5. Validate locally, supplying the same unchanged artifact:

```sh
python3 Apps/RepoPressDesktop/scripts/ci/validate-linux-release-evidence.py \
  path/to/linux-release-evidence.json --artifact path/to/RepoPressDesktop.AppImage
```

The validator checks attachment hashes and, with `--artifact`, recomputes the release artifact hash. It is intentionally fail-closed. The unit test and syntax checks are:

```sh
python3 Apps/RepoPressDesktop/scripts/ci/test-linux-release-evidence.py
python3 -m py_compile Apps/RepoPressDesktop/scripts/ci/validate-linux-release-evidence.py \
  Apps/RepoPressDesktop/scripts/ci/test-linux-release-evidence.py
```

## What this does and does not establish

Automated CI can establish that the validator, packaging checks, and other deterministic checks ran. It cannot establish that a particular GNOME/KDE session, Wayland/X11 compositor, HiDPI scale, IME candidate popup, or screen reader was actually observed. This contract preserves that boundary: it accepts only complete, hash-bound, human-collected evidence and does not claim the checks were automated. A valid document proves that the supplied evidence files matched the named artifact at validation time; it does not prove a tester's observations are independent, continuous, or representative of every machine.
