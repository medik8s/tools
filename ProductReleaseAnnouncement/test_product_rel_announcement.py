from unittest.mock import MagicMock, patch

import pytest
import requests

from product_rel_announcement import (
    build_slack_template,
    build_upstream_template,
    extract_notable_changes,
    get_latest_version,
    is_filler,
)

FAKE_RELEASES = [
    {
        "key": "snr",
        "name": "Self Node Remediation (SNR)",
        "repo": "self-node-remediation",
        "tag": "v0.13.0",
        "link": "https://github.com/medik8s/self-node-remediation/releases/tag/v0.13.0",
        "changes": ["Add custom node selector", "Fix daemonset timeout"],
    },
    {
        "key": "far",
        "name": "Fence Agents Remediation (FAR)",
        "repo": "fence-agents-remediation",
        "tag": "v0.8.0",
        "link": "https://github.com/medik8s/fence-agents-remediation/releases/tag/v0.8.0",
        "changes": ["Validate fence agent parameters"],
    },
]


class TestExtractNotableChanges:
    def test_markdown_heading_format(self):
        body = (
            "# Release v0.13.0\n"
            "Some intro text.\n"
            "## Notable Changes\n"
            "- Add custom node selector\n"
            "- Fix daemonset timeout\n"
            "## Other Section\n"
            "Other content.\n"
        )
        assert extract_notable_changes(body) == [
            "Add custom node selector",
            "Fix daemonset timeout",
        ]

    def test_bold_format(self):
        body = (
            "**Notable Changes**\n"
            "* First change\n"
            "* Second change\n"
            "**Other Section**\n"
            "Other content.\n"
        )
        assert extract_notable_changes(body) == [
            "First change",
            "Second change",
        ]

    def test_empty_body(self):
        assert extract_notable_changes("") == []
        assert extract_notable_changes(None) == []

    def test_no_notable_changes_section(self):
        body = "# Release v1.0\nJust a regular release.\n"
        assert extract_notable_changes(body) == []


class TestBuildUpstreamTemplate:
    def test_full_message(self):
        expected = (
            "On behalf of the Medik8s team, I am pleased to announce a new round of releases\n"
            "for our operators. All releases are now available on the Kubernetes OperatorHub\n"
            "and OKD.\n"
            "\n"
            "The release consists of these operators:\n"
            "\n"
            "**Self Node Remediation (SNR) v0.13.0**\n"
            "- Add custom node selector\n"
            "- Fix daemonset timeout\n"
            "https://github.com/medik8s/self-node-remediation/releases/tag/v0.13.0\n"
            "\n"
            "**Fence Agents Remediation (FAR) v0.8.0**\n"
            "- Validate fence agent parameters\n"
            "https://github.com/medik8s/fence-agents-remediation/releases/tag/v0.8.0\n"
            "\n"
            "For more, visit our website https://www.medik8s.io/, contribute on GitHub\n"
            "https://github.com/medik8s, and DM for more.\n"
        )
        assert build_upstream_template(FAKE_RELEASES) == expected

    def test_filler_entries_filtered(self):
        releases = [
            {**FAKE_RELEASES[0], "changes": ["Add custom node selector", "Internal improvements"]},
            {**FAKE_RELEASES[1], "changes": ["Several internal updates and improvements"]},
        ]
        result = build_upstream_template(releases)
        assert "Internal improvements" not in result
        assert "Several internal updates and improvements" not in result
        assert "Add custom node selector" in result

    def test_no_notable_changes(self):
        releases = [
            {**FAKE_RELEASES[0], "changes": []},
            {**FAKE_RELEASES[1], "changes": []},
        ]
        result = build_upstream_template(releases)
        assert "- " not in result.split("operators:\n\n", 1)[1].split("For more")[0]
        assert "**Self Node Remediation (SNR) v0.13.0**" in result


class TestBuildSlackTemplate:
    def test_full_message_grouped_by_operator(self):
        expected = (
            "The OCP Workload Availability team is thrilled to announce the RHWA-4.21-0 release of\n"
            "Self Node Remediation (SNR) v0.13.0,\n"
            "and Fence Agents Remediation (FAR) v0.8.0.\n"
            "\n"
            "The new operators are available upstream for Kubernetes and OKD, and with\n"
            "support on the OpenShift Container Platform (as RHWA). See our release notes\n"
            "for the complete list of changes at\n"
            "https://docs.redhat.com/en/documentation/workload_availability_for_red_hat_openshift/4.21-0/html/release_notes/\n"
            "\n"
            "Notable Changes\n"
            "\n"
            "**Self Node Remediation (SNR)**\n"
            "- Add custom node selector\n"
            "- Fix daemonset timeout\n"
            "\n"
            "**Fence Agents Remediation (FAR)**\n"
            "- Validate fence agent parameters\n"
            "\n"
        )
        assert build_slack_template(FAKE_RELEASES, "4.21-0") == expected

    def test_curated_changes_override(self):
        curated = ["Storm recovery for NHC", "Aligned taint usage in SNR and FAR"]
        expected = (
            "The OCP Workload Availability team is thrilled to announce the RHWA-4.21-0 release of\n"
            "Self Node Remediation (SNR) v0.13.0,\n"
            "and Fence Agents Remediation (FAR) v0.8.0.\n"
            "\n"
            "The new operators are available upstream for Kubernetes and OKD, and with\n"
            "support on the OpenShift Container Platform (as RHWA). See our release notes\n"
            "for the complete list of changes at\n"
            "https://docs.redhat.com/en/documentation/workload_availability_for_red_hat_openshift/4.21-0/html/release_notes/\n"
            "\n"
            "Notable Changes\n"
            "\n"
            "- Storm recovery for NHC\n"
            "- Aligned taint usage in SNR and FAR\n"
        )
        assert build_slack_template(FAKE_RELEASES, "4.21-0", curated) == expected

    def test_filler_entries_filtered(self):
        releases = [
            {**FAKE_RELEASES[0], "changes": ["Add custom node selector", "Internal improvements"]},
            {**FAKE_RELEASES[1], "changes": ["Several internal updates and improvements"]},
        ]
        result = build_slack_template(releases, "4.21-0")
        assert "Internal improvements" not in result
        assert "Several internal updates and improvements" not in result
        assert "Add custom node selector" in result

    def test_all_filler_omits_notable_changes_heading(self):
        releases = [
            {**FAKE_RELEASES[0], "changes": ["Internal improvements"]},
            {**FAKE_RELEASES[1], "changes": ["Several internal updates and improvements"]},
        ]
        result = build_slack_template(releases, "4.21-0")
        assert "Notable Changes" not in result

    def test_single_operator(self):
        releases = [FAKE_RELEASES[0]]
        expected_opening = (
            "The OCP Workload Availability team is thrilled to announce the RHWA-4.22-0 release of\n"
            "Self Node Remediation (SNR) v0.13.0.\n"
        )
        result = build_slack_template(releases, "4.22-0")
        assert result.startswith(expected_opening)
        assert "and " not in result.split("\n")[1]


class TestIsFiller:
    def test_filler_entries(self):
        assert is_filler("Internal improvements")
        assert is_filler("internal improvements")
        assert is_filler("Several internal improvements")
        assert is_filler("Several internal updates and improvements")
        assert is_filler("Bug fixes and internal updates")

    def test_real_entries(self):
        assert not is_filler("Add custom node selector")
        assert not is_filler("Fix daemonset timeout")
        assert not is_filler("Storm recovery mechanism")


class TestGetLatestVersion:
    def test_happy_path(self):
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "tag_name": "v0.13.0",
            "html_url": "https://github.com/medik8s/self-node-remediation/releases/tag/v0.13.0",
            "body": "## Notable Changes\n- Fix timeout\n",
        }
        with patch("product_rel_announcement.requests.get", return_value=mock_response) as mock_get:
            result = get_latest_version("self-node-remediation")
            mock_get.assert_called_once_with(
                "https://api.github.com/repos/medik8s/self-node-remediation/releases/latest",
                timeout=10,
                headers={"User-Agent": "medik8s-release-announcer"},
            )
        assert result == {
            "tag": "v0.13.0",
            "link": "https://github.com/medik8s/self-node-remediation/releases/tag/v0.13.0",
            "changes": ["Fix timeout"],
        }
        mock_response.raise_for_status.assert_called_once()

    def test_http_error(self):
        mock_response = MagicMock()
        mock_response.raise_for_status.side_effect = requests.HTTPError("404")
        with patch("product_rel_announcement.requests.get", return_value=mock_response):
            with pytest.raises(requests.HTTPError):
                get_latest_version("nonexistent-operator")
