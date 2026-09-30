# AGENTS.md - AI Agent Collaboration & Development Guidelines

> This document defines the operational context, architectural constraints, security rules, and workflow standards for AI coding agents (Antigravity, Claude Code, Cursor, Copilot, etc.) working in this repository.

---

## 1. Project Overview & Architecture

- **Project Name**: `nexterm-patch`
- **Purpose**: Provides non-invasive hot-patching scripts (`patch-and-start.sh`), diagnostics, and stability enhancements for the containerized Web terminal **Nexterm** (`gnmyt/Nexterm`).
- **Deployment Mode**: Docker Compose Entrypoint Wrapper (`entrypoint: ["/bin/sh", "/app/patch-and-start.sh"]`).
- **Core Technology Stack**:
  - **Bash / POSIX sh**: Shell scripting for entrypoint hot-patching.
  - **Node.js / Express / WebSocket (`ws`)**: Nexterm server-side orchestration and API routing.
  - **C Binary (`nexterm-engine`)**: Compiled backend engine managing raw TCP sockets and `libssh2` connections.
  - **Docker / Linux Sysctl**: Containerized networking and TCP keepalive tuning.

### Architectural Mental Model
```text
[ Browser Web Client ]
       │  ▲
       │  │ (WebSocket: /api/ws/ssh, /api/ws/sftp)
       ▼  │
[ Node.js Server (`server/`) ]
  - SessionManager.js (Tracks sessions & timers)
  - hooks/ssh.js (Terminal WebSocket handling)
  - routes/sftpWS.js (SFTP WebSocket handling)
  - ConnectionService.js (Bridge to C Engine)
       │  ▲
       │  │ (Local IPC / dataSocket: port 7800)
       ▼  │
[ C Engine (`/usr/local/bin/nexterm-engine`) ]
  - libssh2 (SSH & SFTP network protocol implementation)
       │  ▲
       │  │ (TCP / IP Socket: SO_KEEPALIVE)
       ▼  │
[ Remote SSH / SFTP Server ]
```

---

## 2. Core Rules & Constraints for AI Agents

### 🚨 Critical Safety & Security Rules
1. **Zero Secret Leakage**:
   - **NEVER** commit or log real `ENCRYPTION_KEY` values, SSH private keys, database passwords, or auth tokens.
   - Always use placeholders (e.g., `your_encryption_key_here`, `your_token_here`) in documentation and sample configurations.
   - Before any `git push` or commit, scan staged files for potential secret patterns.
2. **Privacy Protection**:
   - Sanitize all real hostnames, public IP addresses, and private usernames in examples and commit logs.

### ⚙️ Nexterm Technical Realities (Avoid Hallucinations)
1. **No Node.js `ssh2`**:
   - Nexterm does **NOT** use the npm `ssh2` package for SSH or SFTP.
   - Never generate code or `sed` commands searching for `require("ssh2")` or `sshClient.connect(...)`.
2. **Defensive Hook Injection**:
   - In `hooks/ssh.js`, `logger` is **not** imported by default. Always ensure `const logger = require("../utils/logger");` is injected before calling `logger.*`.
   - **All injected event handlers and log calls MUST be wrapped in `try { ... } catch(e) {}`**. An unhandled exception in an async WebSocket callback will crash the entire Node.js server and kill all active connections.
3. **No 0x0 Terminal Resizing**:
   - Never send `sendSessionResize(sessionId, 0, 0)` as a keepalive. Setting terminal dimensions to 0 causes `SIGWINCH` corruption in readline, vim, and tmux.
4. **SFTP Idle Disconnect Prevention**:
   - SFTP idle drops occur because `engine/src/net/sftp.c` only polls internal IPC (`data_fd`). Keepalive MUST be driven by periodic lightweight `sftpClient.realpath(".")` calls from Node.js (`ConnectionService.js`).

---

## 3. Standard Commands & Verification

### File Testing & Validation
```bash
# Test sed injections against a copy of a file before applying
cp target.js /tmp/test.js
sed -i '...' /tmp/test.js
node -c /tmp/test.js    # Verify JavaScript syntax
rm /tmp/test.js
```

### Git & Release Workflow
- Follow [Conventional Commits](https://www.conventionalcommits.org/):
  - `feat: ...` for new patches or capabilities.
  - `fix: ...` for bug fixes and crash prevention.
  - `docs: ...` for documentation and conversation archive updates.
- Always check `git status` and `git diff` before committing.
- When committing changes to `patch-and-start.sh`, ensure:
  1. `chmod +x patch-and-start.sh` is preserved.
  2. `README.md` reflects updated version numbers.
  3. `docs/conversation_history.md` records the problem, analysis, and solution.

---

## 4. Production Diagnostics Reference

When assisting the user with runtime troubleshooting, recommend these commands:

```bash
# 1. Monitor real-time disconnect diagnostics
docker logs -f <container_name> | grep DISCONNECT-LOG

# 2. Inspect recent container logs
docker logs --tail 200 <container_name>

# 3. Verify patch injection status inside container
docker exec -it <container_name> grep -n "Infinity" /app/server/lib/SessionManager.js
docker exec -it <container_name> grep -n "sftpKeepAlive" /app/server/lib/ConnectionService.js
docker exec -it <container_name> grep -n "updateActivity" /app/server/hooks/ssh.js

# 4. Restart container after updating patch script
cd /opt/docker/nexterm && docker compose restart
```

---

## 5. Agent Interaction Style

- **Concise & Direct**: Explain root causes clearly with code snippets before proposing fixes.
- **Verification First**: Verify assumptions against actual source code rather than guessing.
- **Maintain Documentation Integrity**: Preserve existing comments, changelogs, and formatting when modifying files.
