"""Execute the publisher's real metadata script without building images."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ".github/workflows/build-kube-proxy-images.yml"


def metadata(ref_type, name):
    revision = os.environ.get("WORKFLOW_TEST_REVISION")
    source = subprocess.check_output(
        ["git", "show", f"{revision}:{WORKFLOW}"], cwd=ROOT, text=True
    ) if revision else (ROOT / WORKFLOW).read_text()
    block = re.search(r"        run: \|\n((?:          .*\n|\n)+)", source)
    if not block:
        raise AssertionError("metadata script not found")
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "output"
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", textwrap.dedent(block[1])],
            env={**os.environ, "GITHUB_REF_TYPE": ref_type, "GITHUB_REF_NAME": name,
                 "GITHUB_SHA": "a" * 40, "GITHUB_OUTPUT": str(output)},
            capture_output=True, text=True,
        )
        values = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
        return result, values


class PublicationMetadata(unittest.TestCase):
    def test_master_cannot_overwrite_release_tags(self):
        result, values = metadata("branch", "master")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["suffix"], "-master-" + "a" * 12)

    def test_release_branch_gets_revision_specific_tags(self):
        result, values = metadata("branch", "appmana/kube-proxy-v1.36.4")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["suffix"], "-appmana-kube-proxy-v1.36.4-" + "a" * 12)

    def test_release_publishes_only_selected_version(self):
        import json
        tag = "v1.36.4-appmana.post.14-calico-hostprocess"
        result, values = metadata("tag", tag)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["suffix"], "")
        self.assertEqual([v["image_tag"] for v in json.loads(values["matrix"])], [tag])

    def test_unknown_release_refused(self):
        result, _ = metadata("tag", "v1.36.4-appmana.post.999-calico-hostprocess")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
