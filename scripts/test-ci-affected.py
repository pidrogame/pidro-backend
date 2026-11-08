"""Exercise the selector's public CLI in a disposable Git repository, no ExUnit sweep."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("ci-affected.py").resolve()


class SelectionTest(unittest.TestCase):
    def test_changed_module_transitive_consumer_and_smoke_not_unrelated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True).strip()

            def write(name, text):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)

            git("init", "-q")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Test")
            engine = "apps/pidro_engine/"
            write(engine + "lib/score.ex", "defmodule Pidro.Score do\nend\n")
            write(engine + "lib/game.ex", "defmodule Pidro.Game do\n alias Pidro.Score\nend\n")
            write(engine + "test/score_test.exs", "alias Pidro.Score\n")
            write(engine + "test/game_test.exs", "alias Pidro.Game\n")
            write(engine + "test/other_test.exs", "alias Other\n")
            write(engine + "test/unit/card_test.exs", "# smoke\n")
            write("apps/pidro_server/test/pidro_server_web/controllers/error_json_test.exs", "# smoke\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            write(engine + "lib/score.ex", "defmodule Pidro.Score do\n # changed\nend\n")
            git("commit", "-qam", "score")

            def select(before):
                result = subprocess.run(["python3", str(SCRIPT), before], cwd=root,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return json.loads(result.stdout)

            chosen = select(base)
            self.assertIn(engine + "test/score_test.exs", chosen)
            self.assertIn(engine + "test/game_test.exs", chosen)
            self.assertNotIn(engine + "test/other_test.exs", chosen)
            self.assertIn(engine + "test/unit/card_test.exs", chosen)
            self.assertEqual(len(select("missing-base")), 2)
            before_docs = git("rev-parse", "HEAD")
            write("docs/testing.md", "# Policy\n")
            git("add", ".")
            git("commit", "-qm", "docs")
            self.assertEqual(len(select(before_docs)), 2)
            before_delete = git("rev-parse", "HEAD")
            git("rm", "-q", engine + "lib/score.ex")
            git("commit", "-qm", "remove score module")
            self.assertIn(engine + "test/game_test.exs", select(before_delete))
            self.assertNotIn(engine + "test/other_test.exs", select(before_delete))


if __name__ == "__main__":
    unittest.main()
