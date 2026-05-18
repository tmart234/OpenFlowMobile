import sys
from pathlib import Path

# Make `scripts/` importable as a flat module path in tests
# (build_registry, fetch_smap), independent of the test runner's cwd.
SCRIPTS_DIR = Path(__file__).resolve().parent.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
