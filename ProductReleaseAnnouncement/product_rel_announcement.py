#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# vi: set ft=python :
"""
Auto-generate social media posts for Medik8s release announcements by filling in the latest tags and
release information.

Usage:
    product_rel_announcement.py [--markdown] [--html] [--slack --rhwa-version=<ver> [--slack-changes=<file>]] [--operator=<ops>]

Options:
    -m, --markdown              Write the upstream (Google Group) announcement to release.md
    -w, --html                  Write the upstream (Google Group) announcement to release.html
    -s, --slack                 Write the internal (Slack #forum-ocp-workload-availability) announcement to release-slack.txt
    --rhwa-version=<ver>        RHWA release version (e.g. 4.21-0), required with --slack
    --slack-changes=<file>      File with curated notable changes for Slack (one per line). Falls back to GitHub
    --operator=<ops>            Comma-separated operator keys to include (e.g. snr,far). Default: all
"""
import re
import sys

import markdown
import requests
from docopt import docopt

OPERATORS = [
    {"key": "nhc", "name": "Node HealthCheck Operator (NHC)", "repo": "node-healthcheck-operator"},
    {"key": "snr", "name": "Self Node Remediation (SNR)", "repo": "self-node-remediation"},
    {"key": "far", "name": "Fence Agents Remediation (FAR)", "repo": "fence-agents-remediation"},
    {"key": "mdr", "name": "Machine Deletion Remediation (MDR)", "repo": "machine-deletion-remediation"},
    {"key": "sbr", "name": "Storage Based Remediation (SBR)", "repo": "storage-based-remediation"},
    {"key": "nmo", "name": "Node Maintenance Operator (NMO)", "repo": "node-maintenance-operator"},
]


def main():
    arguments = docopt(__doc__)

    if not any([arguments['--markdown'], arguments['--html'], arguments['--slack']]):
        sys.exit("Error: specify at least one output format: --markdown, --html, or --slack")

    if arguments['--slack'] and not arguments['--rhwa-version']:
        sys.exit("Error: --rhwa-version is required when using --slack")

    selected_keys = None
    if arguments['--operator']:
        selected_keys = [k.strip().lower() for k in arguments['--operator'].split(',')]

    operators = OPERATORS
    if selected_keys:
        valid_keys = {op['key'] for op in OPERATORS}
        invalid_keys = set(selected_keys) - valid_keys
        if invalid_keys:
            sys.exit(f"Error: unrecognized operators: {', '.join(sorted(invalid_keys))}")
        operators = [op for op in OPERATORS if op['key'] in selected_keys]

    releases = []
    for op in operators:
        try:
            info = get_latest_version(op['repo'])
        except requests.HTTPError as e:
            sys.exit(f"Error: failed to fetch release for {op['repo']}: {e}")
        releases.append({**op, **info})

    if arguments['--markdown'] or arguments['--html']:
        upstream = build_upstream_template(releases)
        if arguments['--markdown']:
            with open('release.md', 'w', encoding='utf-8') as f:
                f.write(upstream)
        if arguments['--html']:
            with open('release.html', 'w', encoding='utf-8') as f:
                f.write(markdown.markdown(upstream))

    if arguments['--slack']:
        curated_changes = None
        if arguments['--slack-changes']:
            with open(arguments['--slack-changes'], 'r', encoding='utf-8') as f:
                curated_changes = [line.strip() for line in f if line.strip()]
        slack = build_slack_template(releases, arguments['--rhwa-version'], curated_changes)
        with open('release-slack.txt', 'w', encoding='utf-8') as f:
            f.write(slack)


def build_upstream_template(releases):
    lines = [
        "On behalf of the Medik8s team, I am pleased to announce a new round of releases",
        "for our operators. All releases are now available on the Kubernetes OperatorHub",
        "and OKD.",
        "",
        "The release consists of these operators:",
        "",
    ]
    for r in releases:
        lines.append(f"**{r['name']} {r['tag']}**")
        for change in r['changes']:
            if not is_filler(change):
                lines.append(f"- {change}")
        lines.append(r['link'])
        lines.append("")
    lines.append("For more, visit our website https://www.medik8s.io/, contribute on GitHub")
    lines.append("https://github.com/medik8s, and DM for more.")
    lines.append("")
    return "\n".join(lines)


FILLER_PATTERNS = [
    re.compile(r'^(several\s+)?internal\s+(improvements|updates(\s+and\s+improvements)?)', re.IGNORECASE),
    re.compile(r'^bug\s+fixes\s+and\s+internal\s+updates$', re.IGNORECASE),
]


def is_filler(change):
    return any(p.match(change) for p in FILLER_PATTERNS)


def build_slack_template(releases, rhwa_version, curated_changes=None):
    op_parts = []
    for i, r in enumerate(releases):
        part = f"{r['name']} {r['tag']}"
        if i == len(releases) - 1 and len(releases) > 1:
            op_parts.append(f"and {part}")
        else:
            op_parts.append(part)
    operator_list = ", ".join(op_parts[:-1]) + ",\n" + op_parts[-1] if len(op_parts) > 1 else op_parts[0]

    docs_url = (
        f"https://docs.redhat.com/en/documentation/workload_availability_for_red_hat_openshift"
        f"/{rhwa_version}/html/release_notes/"
    )

    lines = [
        f"The OCP Workload Availability team is thrilled to announce the RHWA-{rhwa_version} release of",
        f"{operator_list}.",
        "",
        "The new operators are available upstream for Kubernetes and OKD, and with",
        "support on the OpenShift Container Platform (as RHWA). See our release notes",
        "for the complete list of changes at",
        docs_url,
    ]

    if curated_changes:
        lines.append("")
        lines.append("Notable Changes")
        lines.append("")
        for change in curated_changes:
            lines.append(f"- {change}")
    else:
        filtered_releases = [(r['name'], [c for c in r['changes'] if not is_filler(c)]) for r in releases]
        if any(changes for _, changes in filtered_releases):
            lines.append("")
            lines.append("Notable Changes")
            lines.append("")
            for name, changes in filtered_releases:
                if changes:
                    lines.append(f"**{name}**")
                    for change in changes:
                        lines.append(f"- {change}")
                    lines.append("")

    lines.append("")
    return "\n".join(lines)


def extract_notable_changes(body):
    if not body:
        return []
    match = re.search(r'(?i)#+\s*notable\s+changes?\s*\n(.*?)(?=\n#+\s|\Z)', body, re.DOTALL)
    if not match:
        match = re.search(r'(?i)\*\*notable\s+changes?\*\*\s*\n(.*?)(?=\n\*\*|\Z)', body, re.DOTALL)
    if not match:
        return []
    section = match.group(1).strip()
    changes = []
    for line in section.splitlines():
        line = line.strip()
        cleaned = re.sub(r'^[-*]\s*', '', line).strip()
        if cleaned:
            changes.append(cleaned)
    return changes


def get_latest_version(op_name: str) -> dict[str, str | list[str]]:
    url = f"https://api.github.com/repos/medik8s/{op_name}/releases/latest"
    response = requests.get(url, timeout=10, headers={"User-Agent": "medik8s-release-announcer"})
    response.raise_for_status()
    data = response.json()
    changes = extract_notable_changes(data.get("body", ""))
    return {"tag": data["tag_name"], "link": data["html_url"], "changes": changes}


if __name__ == "__main__":
    main()
