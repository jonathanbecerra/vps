.DEFAULT_GOAL := help
export DRY_RUN
.PHONY: help install-packages install-tools

help:
	@printf '%s\n' \
	  'First boot:' \
	  '  Run ./setup-vps.sh as root on the Ubuntu box' \
	  '  ./setup-vps.sh --help' \
	  '' \
	  'Host tools:' \
	  '  install-packages    Install Ubuntu packages from config/apt/packages.txt' \
	  '  install-tools       Install pinned tools from config/apt/binaries.tsv'

install-packages:
	@bash scripts/run-root.sh scripts/install-packages.sh

install-tools:
	@bash scripts/run-root.sh scripts/install-tools.sh
