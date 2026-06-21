#!/usr/bin/env python3
"""
Integration tests for pr_link.py - PR->Issue & Kanban Task Linker.

Tests are self-contained (no GitHub API calls). They validate:
  - Issue reference parsing (keyword-prefixed, bare, edge cases)
  - Kanban task ID parsing
  - Body unwrapping from toJSON format
  - Action classification (opened, reopened, merged vs closed)

Run: python3 test_pr_link.py
"""

import json
import os
import sys
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.dirname(__file__) or ".")

from pr_link import (
    parse_issue_refs,
    parse_kanban_refs,
    is_merged,
    main,
)


class TestParseIssueRefs(unittest.TestCase):
    """Unit tests for parse_issue_refs()."""

    def test_keyword_fixes(self):
        body = "Fixes #42 - corrects the null pointer deref"
        self.assertEqual(parse_issue_refs(body), {42})

    def test_keyword_closes(self):
        body = "Closes #7, Closes #8"
        self.assertEqual(parse_issue_refs(body), {7, 8})

    def test_keyword_resolves(self):
        body = "Resolves #100"
        self.assertEqual(parse_issue_refs(body), {100})

    def test_related_to(self):
        body = "Related to #12"
        self.assertEqual(parse_issue_refs(body), {12})

    def test_see_and_ref(self):
        body = "See #1\nRef #2\nRefs #3"
        self.assertEqual(parse_issue_refs(body), {1, 2, 3})

    def test_bare_refs(self):
        body = "Implement #5 and #6 in this PR"
        self.assertEqual(parse_issue_refs(body), {5, 6})

    def test_mixed_keyword_and_bare(self):
        body = "Fixes #1, #2, Related to #3"
        self.assertEqual(parse_issue_refs(body), {1, 2, 3})

    def test_no_refs(self):
        body = "This PR updates the Dockerfile"
        self.assertEqual(parse_issue_refs(body), set())

    def test_empty_body(self):
        self.assertEqual(parse_issue_refs(""), set())
        self.assertEqual(parse_issue_refs(None), set())

    def test_false_positive_patterns(self):
        body = "In C# we use PascalCase; issue #8 is unrelated"
        self.assertEqual(parse_issue_refs(body), {8})

    def test_body_with_url(self):
        body = (
            "Closes #10\n\n"
            "See https://github.com/owner/repo/issues/5 for context"
        )
        self.assertEqual(parse_issue_refs(body), {10})

    def test_case_insensitive_keyword(self):
        body = "fixes #1 CLOSES #2 Resolves #3"
        self.assertEqual(parse_issue_refs(body), {1, 2, 3})


class TestParseKanbanRefs(unittest.TestCase):
    """Unit tests for parse_kanban_refs()."""

    def test_single_ref(self):
        body = "Parent task: t_a0787f6b"
        self.assertEqual(parse_kanban_refs(body), ["t_a0787f6b"])

    def test_multiple_refs(self):
        body = "From task t_a0787f6b and t_bee5dead"
        self.assertEqual(parse_kanban_refs(body),
                         ["t_a0787f6b", "t_bee5dead"])

    def test_no_refs(self):
        self.assertEqual(parse_kanban_refs("No kanban references here"), [])

    def test_empty_body(self):
        self.assertEqual(parse_kanban_refs(""), [])
        self.assertEqual(parse_kanban_refs(None), [])

    def test_partial_match(self):
        body = "t_xyz is not a valid kanban ref but t_a0787f6b is"
        self.assertEqual(parse_kanban_refs(body), ["t_a0787f6b"])


class TestIsMerged(unittest.TestCase):
    """Unit tests for is_merged() - relies on api_call mock."""

    @patch("pr_link.api_call")
    def test_merged_true(self, mock_api_call):
        mock_api_call.return_value = {"merged": True, "state": "closed"}
        self.assertTrue(is_merged(42))

    @patch("pr_link.api_call")
    def test_merged_false_closed(self, mock_api_call):
        mock_api_call.return_value = {"merged": False, "state": "closed"}
        self.assertFalse(is_merged(42))

    @patch("pr_link.api_call")
    def test_merged_false_open(self, mock_api_call):
        mock_api_call.return_value = {"merged": False, "state": "open"}
        self.assertFalse(is_merged(42))

    @patch("pr_link.api_call")
    def test_merged_api_error(self, mock_api_call):
        mock_api_call.return_value = None
        self.assertFalse(is_merged(42))


class TestMainIntegration(unittest.TestCase):
    """Integration-level tests for main() with mocked API calls."""

    def setUp(self):
        self.env_backup = {k: os.environ.get(k) for k in
                           ["GITHUB_TOKEN", "GITHUB_REPOSITORY",
                            "PR_NUMBER", "PR_ACTION", "PR_TITLE",
                            "PR_BODY", "PR_URL"]}

    def tearDown(self):
        for k, v in self.env_backup.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)

    def _set_env(self, **kwargs):
        for k, v in kwargs.items():
            os.environ[k] = str(v)

    @patch("pr_link.api_call")
    def test_open_with_issue_ref(self, mock_api):
        """PR opened referencing #42 should post comment and add label."""
        mock_api.return_value = {"id": 999}
        self._set_env(
            GITHUB_TOKEN="test-only-no-real-value",
            GITHUB_REPOSITORY="test/repo",
            PR_NUMBER=5,
            PR_ACTION="opened",
            PR_TITLE="Fix the widget",
            PR_BODY='"Fixes #42\n\nThis fixes the widget bug"',
            PR_URL="https://github.com/test/repo/pull/5",
        )
        main()

        self.assertGreaterEqual(mock_api.call_count, 4)

        comments = [c for c in mock_api.call_args_list
                    if c[0][0] == "POST"
                    and "/issues/42/comments" in c[0][1]]
        self.assertEqual(len(comments), 1, "Should have exactly 1 comment POST")
        self.assertIn("PR #5 opened", comments[0][0][2]["body"])

        labels = [c for c in mock_api.call_args_list
                  if c[0][0] == "POST"
                  and "/issues/42/labels" in c[0][1]]
        self.assertEqual(len(labels), 1, "Should have exactly 1 label POST")
        self.assertIn("in-review", labels[0][0][2]["labels"])

    @patch("pr_link.api_call")
    def test_merged_with_issue_ref(self, mock_api):
        """PR merged referencing #42 should post merge comment."""
        mock_api.return_value = {"id": 999}
        self._set_env(
            GITHUB_TOKEN="test-only-no-real-value",
            GITHUB_REPOSITORY="test/repo",
            PR_NUMBER=5,
            PR_ACTION="closed",
            PR_TITLE="Fix the widget",
            PR_BODY='"Closes #42"',
            PR_URL="https://github.com/test/repo/pull/5",
        )

        with patch("pr_link.is_merged", return_value=True):
            main()

        comments = [c for c in mock_api.call_args_list
                    if c[0][0] == "POST"
                    and "/issues/42/comments" in c[0][1]]
        self.assertEqual(len(comments), 1, "Should have exactly 1 comment POST")
        self.assertIn("PR #5 merged", comments[0][0][2]["body"])

        labels = [c for c in mock_api.call_args_list
                  if c[0][0] == "POST"
                  and "/issues/42/labels" in c[0][1]]
        self.assertEqual(len(labels), 1, "Should have exactly 1 label POST")
        self.assertIn("merged", labels[0][0][2]["labels"])

    @patch("pr_link.api_call")
    def test_closed_unmerged(self, mock_api):
        """PR closed without merge should post 'closed' comment."""
        mock_api.return_value = {"id": 999}
        self._set_env(
            GITHUB_TOKEN="test-only-no-real-value",
            GITHUB_REPOSITORY="test/repo",
            PR_NUMBER=5,
            PR_ACTION="closed",
            PR_TITLE="Fix the widget",
            PR_BODY='"Closes #42"',
            PR_URL="https://github.com/test/repo/pull/5",
        )

        with patch("pr_link.is_merged", return_value=False):
            main()

        comments = [c for c in mock_api.call_args_list
                    if c[0][0] == "POST"
                    and "/issues/42/comments" in c[0][1]]
        self.assertEqual(len(comments), 1)
        self.assertIn("PR #5 closed (unmerged)", comments[0][0][2]["body"])

    @patch("pr_link.api_call")
    def test_no_refs_does_nothing(self, mock_api):
        """PR with no issue/kanban refs should not make API calls."""
        self._set_env(
            GITHUB_TOKEN="test-only-no-real-value",
            GITHUB_REPOSITORY="test/repo",
            PR_NUMBER=99,
            PR_ACTION="opened",
            PR_TITLE="Update README",
            PR_BODY='"Just a docs update"',
            PR_URL="https://github.com/test/repo/pull/99",
        )
        main()
        mock_api.assert_not_called()

    @patch("pr_link.api_call")
    def test_kanban_ref_emits_event(self, mock_api):
        """PR referencing t_xxxxx should emit KANBAN_EVENT."""
        mock_api.return_value = {"id": 999}
        self._set_env(
            GITHUB_TOKEN="test-only-no-real-value",
            GITHUB_REPOSITORY="test/repo",
            PR_NUMBER=7,
            PR_ACTION="opened",
            PR_TITLE="Review agent",
            PR_BODY='"From task t_a0787f6b and t_deadbeef"',
            PR_URL="https://github.com/test/repo/pull/7",
        )
        import io
        with patch("sys.stderr", new_callable=io.StringIO) as mock_stderr:
            main()
            written = mock_stderr.getvalue()
            self.assertIn("KANBAN_EVENT:", written)
            self.assertIn("t_a0787f6b", written)
            self.assertIn("t_deadbeef", written)

    @patch("pr_link.api_call")
    def test_unhandled_action_skipped(self, mock_api):
        """'synchronize' should be silently skipped."""
        self._set_env(
            GITHUB_TOKEN="test-only-no-real-value",
            GITHUB_REPOSITORY="test/repo",
            PR_NUMBER=10,
            PR_ACTION="synchronize",
            PR_TITLE="WIP",
            PR_BODY='"Fixes #1"',
            PR_URL="https://github.com/test/repo/pull/10",
        )
        main()
        mock_api.assert_not_called()

    def test_missing_token_exits(self):
        """No GITHUB_TOKEN should exit with code 1."""
        self._set_env(
            GITHUB_TOKEN="",
            GITHUB_REPOSITORY="test/repo",
            PR_NUMBER=1,
            PR_ACTION="opened",
            PR_TITLE="Test",
            PR_BODY='"hello"',
            PR_URL="https://example.com",
        )
        with self.assertRaises(SystemExit) as ctx:
            main()
        self.assertEqual(ctx.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
