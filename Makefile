PYTHON := .venv/bin/python

.PHONY: setup run test lint

setup:
	python3 -m venv .venv
	$(PYTHON) -m pip install -r requirements.txt

run:
	$(PYTHON) src/ingest_raw.py
	$(PYTHON) src/pipeline.py

test:
	$(PYTHON) -m unittest discover -s tests -v

lint:
	$(PYTHON) -m compileall -q src tests
