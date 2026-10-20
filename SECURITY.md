# Security

## Scope

This script talks only to `127.0.0.1` (the local qBittorrent Web UI) and reads local log files. It makes no outbound connections.

The qBittorrent Web UI password is stored with `ConvertFrom-SecureString`, which encrypts it with Windows DPAPI under the current user account. It can only be decrypted by the same user on the same machine.

## Reporting a vulnerability

If you find a problem that could expose credentials or torrent traffic, please open a GitHub issue marked **security** rather than publishing details elsewhere first. There is no bug bounty; this is a hobby project.
