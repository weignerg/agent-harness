---
title: "OpenCode Remote Headless Server & Mobile Client"
type: server
date: "2026-10-11"
tags:
  - entity
  - server
  - mobile
---
# OpenCode Remote Headless Server & Mobile Client

## Overview
The OpenCode harness provides a headless remote server service (`opencode-server.service`) running on port `4096` with password authentication.

## Service Specification
- **Systemd Unit**: `opencode-server.service`
- **Internal Bind**: `http://0.0.0.0:4096`
- **Authentication**: Username (`$USER`) and password authentication (stored in `~/.config/opencode-backends/env` with permissions `0600`).

## Mobile Client: OpenCode Mobile
- **Upstream Repository**: [alvarolorentedev/opencode-mobile](https://github.com/alvarolorentedev/opencode-mobile)
- **Local Wi-Fi / LAN Access**: Connect OpenCode Mobile to `http://<LAN_IP>:4096` (e.g. `http://192.168.1.50:4096`).
- **WAN / Remote Access**: Connect via router port forwarding (external port 4096 -> `<LAN_IP>:4096` TCP) or VPN / Tailscale.
- **Authentication Credentials**: Supply the configured server username and password.
