"""Запускает именованные юнит-тесты Mojo без создания сетевых соединений"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests/unit/websockets.mojo"


class WebSocketUnitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="mojelly-ws-unit-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.executable = Path(cls.directory.name) / "websockets-unit"
        sdk = ROOT / ".pixi/envs/default"
        compiler = str(sdk / "bin/mojo") if (sdk / "bin/mojo").is_file() else shutil.which("mojo")
        if not compiler:
            raise RuntimeError("Install the project environment with pixi install")
        environment = os.environ.copy()
        if (sdk / "share/max/modular.cfg").is_file():
            environment["MODULAR_HOME"] = str(sdk / "share/max")
            environment["PATH"] = str(sdk / "bin") + os.pathsep + environment.get("PATH", "")
        # Один бинарный файл содержит независимые функции, выбранная функция задаётся аргументом
        result = subprocess.run(
            [compiler, "build", "-I", str(ROOT), str(SOURCE), "-o", str(cls.executable)],
            cwd=ROOT, env=environment, capture_output=True, text=True, errors="replace", timeout=90,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)


def make_case(name):
    def run_case(self):
        result = subprocess.run(
            [str(self.executable), name], capture_output=True, text=True, errors="replace", timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"ok {name}", result.stdout)
    run_case.__name__ = name
    return run_case


# Список берётся из исходного файла, поэтому новый тест не нужно регистрировать в Python
for name in re.findall(r"^def (test_\w+)\(", SOURCE.read_text(), flags=re.MULTILINE):
    setattr(WebSocketUnitTests, name, make_case(name))


if __name__ == "__main__":
    unittest.main(verbosity=2)
