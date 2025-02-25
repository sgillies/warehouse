BINDIR = $(PWD)/.state/env/bin
GITHUB_ACTIONS := $(shell echo "$${GITHUB_ACTIONS:-false}")
GITHUB_BASE_REF := $(shell echo "$${GITHUB_BASE_REF:-false}")
DB := example
IPYTHON := no
LOCALES := $(shell .state/env/bin/python -c "from warehouse.i18n import KNOWN_LOCALES; print(' '.join(set(KNOWN_LOCALES)-{'en'}))")

# set environment variable WAREHOUSE_IPYTHON_SHELL=1 if IPython
# needed in development environment
ifeq ($(WAREHOUSE_IPYTHON_SHELL), 1)
    IPYTHON = yes
endif

define DEPCHECKER
import sys
from pip_api import parse_requirements

left, right = sys.argv[1:3]
left_reqs = parse_requirements(left).keys()
right_reqs = parse_requirements(right).keys()

extra_in_left = left_reqs - right_reqs
extra_in_right = right_reqs - left_reqs

if extra_in_left:
	for dep in sorted(extra_in_left):
		print("- {}".format(dep))

if extra_in_right:
	for dep in sorted(extra_in_right):
		print("+ {}".format(dep))

if extra_in_left or extra_in_right:
	sys.exit(1)
endef

default:
	@echo "Call a specific subcommand:"
	@echo
	@$(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null\
	| awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}'\
	| sort\
	| egrep -v -e '^[^[:alnum:]]' -e '^$@$$'
	@echo
	@exit 1

.state/env/pyvenv.cfg: requirements/dev.txt requirements/docs.txt requirements/lint.txt requirements/ipython.txt
	# Create our Python 3.8 virtual environment
	rm -rf .state/env
	python3.8 -m venv .state/env

	# install/upgrade general requirements
	.state/env/bin/python -m pip install --upgrade pip setuptools wheel

	# install various types of requirements
	.state/env/bin/python -m pip install -r requirements/dev.txt
	.state/env/bin/python -m pip install -r requirements/docs.txt
	.state/env/bin/python -m pip install -r requirements/lint.txt

	# install ipython if enabled
ifeq ($(IPYTHON),"yes")
	.state/env/bin/python -m pip install -r requirements/ipython.txt
endif

.state/docker-build: Dockerfile package.json package-lock.json requirements/main.txt requirements/deploy.txt
	# Build our docker containers for this project.
	docker-compose build --build-arg IPYTHON=$(IPYTHON) --force-rm web
	docker-compose build --force-rm worker
	docker-compose build --force-rm static

	# Mark the state so we don't rebuild this needlessly.
	mkdir -p .state
	touch .state/docker-build

build:
	@$(MAKE) .state/docker-build

	docker system prune -f --filter "label=com.docker.compose.project=warehouse"

serve: .state/docker-build
	docker-compose up --remove-orphans

debug: .state/docker-build
	docker-compose run --rm --service-ports web

tests: .state/docker-build
	docker-compose run --rm web env -i ENCODING="C.UTF-8" \
								  PATH="/opt/warehouse/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
								  bin/tests --postgresql-host db $(T) $(TESTARGS)

static_tests: .state/docker-build
	docker-compose run --rm static env -i ENCODING="C.UTF-8" \
								  PATH="/opt/warehouse/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
								  bin/static_tests $(T) $(TESTARGS)

static_pipeline: .state/docker-build
	docker-compose run --rm static env -i ENCODING="C.UTF-8" \
								  PATH="/opt/warehouse/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
								  bin/static_pipeline $(T) $(TESTARGS)

reformat: .state/docker-build
	docker-compose run --rm web env -i ENCODING="C.UTF-8" \
								  PATH="/opt/warehouse/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
								  bin/reformat

lint: .state/docker-build
	docker-compose run --rm web env -i ENCODING="C.UTF-8" \
								  PATH="/opt/warehouse/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
								  bin/lint && bin/static_lint

docs: .state/env/pyvenv.cfg
	$(MAKE) -C docs/ doctest SPHINXOPTS="-W" SPHINXBUILD="$(BINDIR)/sphinx-build"
	$(MAKE) -C docs/ html SPHINXOPTS="-W" SPHINXBUILD="$(BINDIR)/sphinx-build"

licenses:
	bin/licenses

export DEPCHECKER
deps: .state/env/pyvenv.cfg
	$(eval TMPDIR := $(shell mktemp -d))
	$(BINDIR)/pip-compile --upgrade --allow-unsafe -o $(TMPDIR)/deploy.txt requirements/deploy.in > /dev/null
	$(BINDIR)/pip-compile --upgrade --allow-unsafe -o $(TMPDIR)/main.txt requirements/main.in > /dev/null
	$(BINDIR)/pip-compile --upgrade --allow-unsafe -o $(TMPDIR)/lint.txt requirements/lint.in > /dev/null
	echo "$$DEPCHECKER" | $(BINDIR)/python - $(TMPDIR)/deploy.txt requirements/deploy.txt
	echo "$$DEPCHECKER" | $(BINDIR)/python - $(TMPDIR)/main.txt requirements/main.txt
	echo "$$DEPCHECKER" | $(BINDIR)/python - $(TMPDIR)/lint.txt requirements/lint.txt
	rm -r $(TMPDIR)
	$(BINDIR)/pip check

requirements/%.txt: requirements/%.in .state/env/pyvenv.cfg
	$(BINDIR)/pip-compile --allow-unsafe --generate-hashes --output-file=$@ $<

github-actions-deps:
ifneq ($(GITHUB_BASE_REF), false)
	git fetch origin $(GITHUB_BASE_REF):refs/remotes/origin/$(GITHUB_BASE_REF)
	# Check that the following diff will exit with 0 or 1
	git diff --name-only FETCH_HEAD || test $? -le 1 || exit 1
	# Make the dependencies if any changed files are requirements files, otherwise exit
	git diff --name-only FETCH_HEAD | grep '^requirements/' || exit 0 && $(MAKE) deps
endif

initdb:
	docker-compose run --rm web psql -h db -d postgres -U postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname ='warehouse';"
	docker-compose run --rm web psql -h db -d postgres -U postgres -c "DROP DATABASE IF EXISTS warehouse"
	docker-compose run --rm web psql -h db -d postgres -U postgres -c "CREATE DATABASE warehouse ENCODING 'UTF8'"
	xz -d -f -k dev/$(DB).sql.xz --stdout | docker-compose run --rm web psql -h db -d warehouse -U postgres -v ON_ERROR_STOP=1 -1 -f -
	docker-compose run --rm web python -m warehouse db upgrade head
	$(MAKE) reindex
	docker-compose run web python -m warehouse sponsors populate-db

reindex:
	docker-compose run --rm web python -m warehouse search reindex

shell:
	docker-compose run --rm web python -m warehouse shell

clean:
	rm -rf dev/*.sql

purge: stop clean
	rm -rf .state
	docker-compose rm --force

stop:
	docker-compose down -v

compile-pot: .state/env/pyvenv.cfg
	PYTHONPATH=$(PWD) $(BINDIR)/pybabel extract \
		-F babel.cfg \
		--omit-header \
		--output="warehouse/locale/messages.pot" \
		warehouse

init-po: .state/env/pyvenv.cfg
	$(BINDIR)/pybabel init \
		--input-file="warehouse/locale/messages.pot" \
		--output-dir="warehouse/locale/" \
		--locale="$(L)"

update-po: .state/env/pyvenv.cfg
	$(BINDIR)/pybabel update \
		--input-file="warehouse/locale/messages.pot" \
		--output-file="warehouse/locale/$(L)/LC_MESSAGES/messages.po" \
		--locale="$(L)"

compile-po: .state/env/pyvenv.cfg
	$(BINDIR)/pybabel compile \
		--input-file="warehouse/locale/$(L)/LC_MESSAGES/messages.po" \
		--directory="warehouse/locale/" \
		--locale="$(L)"

build-mos: compile-pot
	for LOCALE in $(LOCALES) ; do \
		L=$$LOCALE $(MAKE) compile-po ; \
		done

translations: compile-pot
ifneq ($(GITHUB_ACTIONS), false)
	git diff --quiet ./warehouse/locale/messages.pot || (echo "There are outstanding translations, run 'make translations' and commit the changes."; exit 1)
else
endif

.PHONY: default build serve initdb shell tests docs deps clean purge debug stop compile-pot
