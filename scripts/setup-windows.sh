#!/usr/bin/env bash
# Native Windows is not supported. Install WSL2 and an Ubuntu distribution
# (https://learn.microsoft.com/windows/wsl/install), clone into the Linux
# filesystem, and run `make setup-linux` there (docs/guide/BUILDING.md section 1a).
echo "setup-windows: native Windows is not supported; use WSL2 and run 'make setup-linux' inside it" >&2
exit 1
