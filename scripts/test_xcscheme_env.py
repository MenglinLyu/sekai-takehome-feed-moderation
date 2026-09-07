"""Regression checks for syncing SEKAI_BASE_URL into an Xcode scheme."""

from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from xcscheme_env import set_scheme_env

SCHEME = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme>
   <LaunchAction buildConfiguration = "Release">
   </LaunchAction>
</Scheme>
'''


class SchemeEnvTests(unittest.TestCase):
    def test_returns_none_without_existing_file_or_template(self):
        with tempfile.TemporaryDirectory() as directory:
            result = set_scheme_env(Path(directory), "Sekai", "SEKAI_BASE_URL", "http://x:1")
            self.assertIsNone(result)

    def test_creates_from_template_when_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory) / "Template.xcscheme"
            template.write_text(SCHEME)
            path = set_scheme_env(Path(directory), "Sekai Mock", "SEKAI_BASE_URL",
                                  "http://192.168.1.2:8787", template=template)
            self.assertTrue(path.exists())
            variable = ET.parse(path).find("LaunchAction/EnvironmentVariables/EnvironmentVariable")
            self.assertEqual(variable.get("key"), "SEKAI_BASE_URL")
            self.assertEqual(variable.get("value"), "http://192.168.1.2:8787")
            self.assertEqual(variable.get("isEnabled"), "YES")

    def test_updates_existing_scheme_and_preserves_other_variables(self):
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory) / "Template.xcscheme"
            template.write_text(SCHEME)
            path = set_scheme_env(Path(directory), "Sekai", "SEKAI_BASE_URL",
                                  "http://192.168.1.2:8787", template=template)
            tree = ET.parse(path)
            variables = tree.find("LaunchAction/EnvironmentVariables")
            ET.SubElement(variables, "EnvironmentVariable", key="KEEP_ME", value="yes", isEnabled="YES")
            tree.write(path)
            set_scheme_env(Path(directory), "Sekai", "SEKAI_BASE_URL", "http://192.168.1.3:8789")
            variables = ET.parse(path).findall("LaunchAction/EnvironmentVariables/EnvironmentVariable")
            self.assertEqual({v.get("key"): v.get("value") for v in variables},
                             {"KEEP_ME": "yes", "SEKAI_BASE_URL": "http://192.168.1.3:8789"})

    def test_missing_launch_action_raises(self):
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory) / "Template.xcscheme"
            template.write_text("<Scheme></Scheme>")
            with self.assertRaisesRegex(RuntimeError, "Missing LaunchAction"):
                set_scheme_env(Path(directory), "Sekai", "SEKAI_BASE_URL", "http://x:1", template=template)


if __name__ == "__main__":
    unittest.main()
