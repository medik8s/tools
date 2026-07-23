# Product Release Announcement

Generate release announcements for Medik8s operators by fetching the latest tags and notable changes from GitHub.

## Installation

With [uv](https://docs.astral.sh/uv/) (recommended):

```bash
uv venv venv
uv pip install -r requirements.txt --python venv/bin/python
```

Or with the standard library:

```bash
python3 -m venv venv
venv/bin/pip install -r requirements.txt
```

## Usage

```bash
source venv/bin/activate

# Upstream (Google Group) — markdown
./product_rel_announcement.py --markdown

# Upstream — HTML
./product_rel_announcement.py --html

# Both formats
./product_rel_announcement.py --markdown --html

# Internal Slack announcement
./product_rel_announcement.py --slack --rhwa-version 4.21-0

# Only specific operators
./product_rel_announcement.py --markdown --operator snr,far
```

Output files: `release.md`, `release.html`, `release-slack.txt`.

### Options

| Flag | Description |
|------|-------------|
| `--markdown` | Write `release.md` |
| `--html` | Write `release.html` |
| `--slack` | Write `release-slack.txt` (requires `--rhwa-version`) |
| `--rhwa-version=<ver>` | RHWA release version (e.g. `4.21-0`) |
| `--slack-changes=<file>` | File with curated notable changes for Slack (one per line). Falls back to GitHub |
| `--operator=<ops>` | Comma-separated operator keys: `nmo`, `nhc`, `snr`, `far`, `mdr`, `sbr` |

## Tests

```bash
make test
```

This creates the venv (if needed), installs dependencies, and runs pytest. If `uv` is available it will be used automatically, otherwise it falls back to `python3 -m venv`.

To clean up generated files and the venv:

```bash
make clean
```
