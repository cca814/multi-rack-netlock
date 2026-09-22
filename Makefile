SHELL := /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
VENV ?= .venv
SUDO ?= sudo
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SIM_PYTHON := $(abspath $(VENV))/bin/python
CONTROLLER_VENV ?= .venv-controller
CONTROLLER_PYTHON := $(abspath $(CONTROLLER_VENV))/bin/python
P4C ?= p4c-bm2-ss
P4_SWITCH ?= simple_switch_grpc
P4_BUILD_DIR ?= build
P4INFO := $(abspath $(P4_BUILD_DIR))/netlock.p4info.txt
BMV2_JSON := $(abspath $(P4_BUILD_DIR))/netlock.json
P4_CONFIG ?= controller/config.example.json
P4_CONFIG_PATH := $(abspath $(P4_CONFIG))
P4_GRPC_ADDR ?= 127.0.0.1:9559
P4_DEVICE_ID ?= 0
P4_ELECTION_ID ?= 0,1
CLIENT_CYCLES ?= 10
CLIENT_HOLD_TIME ?= 0.5
CLIENT_REPLY_TIMEOUT ?= 5.0

CLIENT_INIT = from simulate.client.main import Client; from simulate.common.config import Scenario, SERVER_QPN, Q_KEY; client = Client("02:00:00:00:00:01", "10.200.0.1", "nl-client", "10.200.0.2", "02:00:00:00:00:02", SERVER_QPN, Q_KEY, Scenario.RANDOM, 101)
SERVER_INIT = from simulate.server.main import Server; server = Server("02:00:00:00:00:02", "10.200.0.2", "nl-server")

.PHONY: help sim-deps sim-venv sim-setup sim-up sim-down sim-client-shell sim-server-shell
.PHONY: controller-venv p4-check-tools p4-check-network p4-setup p4-up p4-down
.PHONY: p4-build p4-switch p4-rules p4-rules-dry-run p4-client p4-server
.PHONY: p4-client-shell p4-server-shell

help:
	@echo 'make sim-deps          Install Ubuntu prerequisites (sudo apt-get)'
	@echo 'make sim-setup         Create Python environment and client/server network'
	@echo 'make sim-client-shell Open Python in the client namespace'
	@echo 'make sim-server-shell Open Python in the server namespace'
	@echo 'make sim-down          Remove the simulation network'
	@echo 'make p4-setup          Install Python dependencies, compile P4, create switch topology'
	@echo 'make p4-up             Create only the client-switch-server network'
	@echo 'make p4-build          Compile P4 into BMv2 JSON and P4Info'
	@echo 'make p4-switch         Run simple_switch_grpc in the foreground (terminal 1)'
	@echo 'make p4-rules          Load the pipeline and install routes (terminal 2)'
	@echo 'make p4-rules-dry-run  Preview rules without a switch or controller dependencies'
	@echo 'make p4-server         Start the server in the foreground (terminal 2, after rules)'
	@echo 'make p4-client         Run 10 acquire/release cycles (terminal 3)'
	@echo 'make p4-client-shell   Open the interactive client instead'
	@echo 'make p4-server-shell   Open the interactive server instead'
	@echo 'make p4-down           Remove the network after stopping the switch and endpoints'
	@echo 'Requires Linux, p4c-bm2-ss, and simple_switch_grpc; sim-deps installs basic Ubuntu tools.'
	@echo 'Example: make p4-client CLIENT_CYCLES=100 CLIENT_HOLD_TIME=0.1 CLIENT_REPLY_TIMEOUT=10'

sim-deps:
	$(SUDO) apt-get update
	$(SUDO) apt-get install -y python3 python3-venv iproute2

sim-venv:
	$(PYTHON) -m venv "$(VENV)"
	"$(SIM_PYTHON)" -m pip install -r "$(ROOT)/simulate/requirements.txt"

sim-setup: sim-venv
	$(MAKE) sim-up

sim-up:
	$(SUDO) bash "$(ROOT)/simulate/network.sh" up

sim-down:
	$(SUDO) bash "$(ROOT)/simulate/network.sh" down

sim-client-shell:
	cd "$(ROOT)" && $(SUDO) ip netns exec netlock-client "$(SIM_PYTHON)" -i -c '$(CLIENT_INIT)'

sim-server-shell:
	cd "$(ROOT)" && $(SUDO) ip netns exec netlock-server "$(SIM_PYTHON)" -i -c '$(SERVER_INIT)'

controller-venv:
	$(PYTHON) -m venv "$(CONTROLLER_VENV)"
	"$(CONTROLLER_PYTHON)" -m pip install -r "$(ROOT)/controller/requirements.txt"

p4-check-tools:
	@test "$$(uname -s)" = Linux || { echo 'The P4 topology requires Linux network namespaces.' >&2; exit 1; }
	@command -v ip >/dev/null || { echo 'Missing iproute2: run make sim-deps.' >&2; exit 1; }
	@command -v "$(P4C)" >/dev/null || { echo 'Install p4c-bm2-ss or set P4C=/path/to/compiler.' >&2; exit 1; }
	@command -v "$(P4_SWITCH)" >/dev/null || { echo 'Install simple_switch_grpc or set P4_SWITCH=/path/to/switch.' >&2; exit 1; }

p4-check-network:
	@for interface in sw-server sw-client; do \
		ip link show dev "$$interface" >/dev/null 2>&1 || { echo "Missing $$interface: run make p4-setup or make p4-up." >&2; exit 1; }; \
	done

p4-setup: p4-check-tools
	$(MAKE) sim-venv controller-venv p4-build
	$(MAKE) p4-up

p4-up:
	$(SUDO) bash "$(ROOT)/simulate/network.sh" up-p4

p4-down: sim-down

p4-build:
	mkdir -p "$(abspath $(P4_BUILD_DIR))"
	cd "$(ROOT)" && "$(P4C)" --std p4-16 --p4runtime-files "$(P4INFO)" -o "$(BMV2_JSON)" p4/main.p4

p4-switch: p4-check-network
	$(SUDO) "$(P4_SWITCH)" --device-id "$(P4_DEVICE_ID)" --no-p4 \
		-i 1@sw-server -i 2@sw-client -- --grpc-server-addr "$(P4_GRPC_ADDR)"

p4-rules:
	cd "$(ROOT)" && "$(CONTROLLER_PYTHON)" controller/main.py --config "$(P4_CONFIG_PATH)" \
		--grpc-addr "$(P4_GRPC_ADDR)" --device-id "$(P4_DEVICE_ID)" --election-id "$(P4_ELECTION_ID)" \
		--p4info "$(P4INFO)" --bmv2-json "$(BMV2_JSON)"

p4-rules-dry-run:
	cd "$(ROOT)" && $(PYTHON) controller/main.py --config "$(P4_CONFIG_PATH)" \
		--grpc-addr "$(P4_GRPC_ADDR)" --device-id "$(P4_DEVICE_ID)" --election-id "$(P4_ELECTION_ID)" --dry-run

p4-server: p4-check-network
	cd "$(ROOT)" && $(SUDO) ip netns exec netlock-server "$(SIM_PYTHON)" -c '$(SERVER_INIT); server.start()'

p4-client: p4-check-network
	cd "$(ROOT)" && $(SUDO) ip netns exec netlock-client "$(SIM_PYTHON)" -c '$(CLIENT_INIT); import sys; import simulate.client.main as client_module; client_module.NUM_OF_LOCK_TO_ACQUIRED = int(sys.argv[1]); client_module.HOLD_TIME = float(sys.argv[2]); grants = client.start(reply_timeout=float(sys.argv[3])); print("Completed", len(grants), "lock cycles")' "$(CLIENT_CYCLES)" "$(CLIENT_HOLD_TIME)" "$(CLIENT_REPLY_TIMEOUT)"

p4-client-shell: p4-check-network
	$(MAKE) sim-client-shell

p4-server-shell: p4-check-network
	$(MAKE) sim-server-shell
