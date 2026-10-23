import importlib
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import ingest_raw
import pipeline


class LayoutTests(unittest.TestCase):
    def test_sql_paths(self):
        self.assertEqual(Path(ingest_raw.SQL_FILE), ROOT / "sql/raw_pulsefit.sql")
        self.assertEqual(Path(pipeline.BUILD_SQL), ROOT / "sql/build_pulsefit.sql")
        self.assertEqual(Path(pipeline.STAR_SQL), ROOT / "sql/star_pulsefit.sql")
        for path in (ingest_raw.SQL_FILE, pipeline.BUILD_SQL, pipeline.STAR_SQL):
            self.assertTrue(Path(path).is_file())

    def test_bundled_sources(self):
        self.assertEqual(Path(ingest_raw.DATA_DIR), ROOT / "data")
        filenames = [source[2] for source in ingest_raw.CSV_SOURCES]
        for filename in filenames + ["subscriptions.json"]:
            self.assertTrue((Path(ingest_raw.DATA_DIR) / filename).is_file())

    def test_shared_output_directory(self):
        self.assertEqual(Path(ingest_raw.OUTPUTS_DIR), ROOT / "outputs")
        self.assertEqual(ingest_raw.OUTPUTS_DIR, pipeline.OUTPUTS_DIR)

    def test_database_configuration(self):
        try:
            with patch.dict(os.environ, {}, clear=True):
                for module in (ingest_raw, pipeline):
                    importlib.reload(module)
                    self.assertEqual(module.DB_NAME, "pulsefit_db")
            with patch.dict(os.environ, {"PGDATABASE": "custom_sample_db"}):
                for module in (ingest_raw, pipeline):
                    importlib.reload(module)
                    self.assertEqual(module.DB_NAME, "custom_sample_db")
        finally:
            for module in (ingest_raw, pipeline):
                importlib.reload(module)
