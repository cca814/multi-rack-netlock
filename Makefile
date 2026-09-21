SHELL := /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
VENV ?= .venv
SUDO ?= sudo
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SIM_PYTHON := $(abspath $(VENV))/bin/python

.PHONY: help sim-deps sim-venv sim-setup sim-up sim-down sim-client-shell sim-server-shell

help:
	@echo 'make sim-deps          Install Ubuntu prerequisites (sudo apt-get)'
	@echo 'make sim-setup         Create Python environment and client/server network'
	@echo 'make sim-client-shell Open Python in the client namespace'
	@echo 'make sim-server-shell Open Python in the server namespace'
	@echo 'make sim-down          Remove the simulation network'

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
	cd "$(ROOT)" && $(SUDO) ip netns exec netlock-client "$(SIM_PYTHON)" -i -c 'from simulate.client.main import Client; from simulate.common.config import Scenario, SERVER_QPN, Q_KEY; client = Client("02:00:00:00:00:01", "10.200.0.1", "nl-client", "10.200.0.2", "02:00:00:00:00:02", SERVER_QPN, Q_KEY, Scenario.RANDOM, 101)'

sim-server-shell:
	cd "$(ROOT)" && $(SUDO) ip netns exec netlock-server "$(SIM_PYTHON)" -i -c 'from simulate.server.main import Server; server = Server("02:00:00:00:00:02", "10.200.0.2", "nl-server")'
