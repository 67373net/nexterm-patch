#!/bin/sh
set -e

# ==============================================================================
# Nexterm 增强版防断连与多窗口防崩溃补丁脚本 (v1.3.0 - 含 SFTP 保活与防断开)
#
# 【核心功能说明】
# 1. 修复 SSH 活跃时间刷新与多窗口防崩溃 (hooks/ssh.js)：
#    - 补全 logger 引用，根除多窗口/跨设备同步关闭标签页时进程崩溃重启的问题。
#    - 键盘输入与终端回显自动刷新 session.lastActivity。
#
# 2. 解除 6 小时强杀机制 (SessionManager.js)：
#    - 超时检测由 6 小时改为 Infinity，并增加活跃 WebSocket 连接保护。
#
# 3. 增强 SSH 底层断连诊断日志 (ConnectionService.js)：
#    - 捕获 SSH 正常挂断 (EOF) 与网络异常 (Socket Error)。
#
# 4. 彻底解决 SFTP 闲置断开与超时 (ConnectionService.js & routes/sftpWS.js) [v1.3.0 新增]：
#    - 注入 SFTP 底层主动保活心跳：每 25 秒自动发送一次轻量 realpath(".") 请求，
#      唤醒 C 引擎并向远程 SSH 服务器发送应用层包，穿透 NAT 防火墙，并使 libssh2 能够及时响应服务端的 ClientAlive 心跳。
#    - 注入 SFTP WebSocket 层保活 Ping：防止浏览器后台挂起或反向代理（Nginx/CF）超时断开。
#    - 用户在 SFTP 文件管理器中执行任何操作时均自动刷新活跃时间。
#    - 注入 SFTP 断开诊断日志 ([DISCONNECT-LOG])。
#
# 【运维排查常用指令】
# 1. 动态过滤断连诊断日志：
#    docker logs -f <container_name> | grep DISCONNECT-LOG
#
# 2. 检查补丁是否在容器中正确生效：
#    docker exec -it <container_name> grep -n "sftpKeepAlive" /app/server/lib/ConnectionService.js
#    docker exec -it <container_name> grep -n "updateActivity" /app/server/hooks/ssh.js
#    docker exec -it <container_name> grep -n "Infinity" /app/server/lib/SessionManager.js
#
# 3. 宿主机快速重启容器服务：
#    cd /opt/docker/nexterm && docker compose restart
# ==============================================================================

echo "[Nexterm-Patch] 正在检查并应用连接防断开与防崩溃补丁 (SSH & SFTP)..."

# 1. 修复 hooks/ssh.js：引入 logger 并注入活跃刷新与安全断连日志
if [ -f /app/server/hooks/ssh.js ]; then
    sed -i '1i const logger = require("../utils/logger");' /app/server/hooks/ssh.js
    sed -i '/SessionManager.markTyping(sessionId, ws);/a \        SessionManager.updateActivity(sessionId);' /app/server/hooks/ssh.js
    sed -i '/ws.readyState === ws.OPEN && ws.send/i \        SessionManager.updateActivity(sessionId);' /app/server/hooks/ssh.js
    sed -i '/ws\.on("close", async () => {/a \        try { logger.system(`[DISCONNECT-LOG] 前端SSH标签页关闭: ${entry?.name || sessionId}`); } catch(e){}' /app/server/hooks/ssh.js
    echo "[Nexterm-Patch] 1. hooks/ssh.js 补丁注入成功 (SSH 活跃刷新与防崩溃)"
fi

# 2. 修复 SessionManager.js：解除 6 小时限制，保护当前活跃连接
if [ -f /app/server/lib/SessionManager.js ]; then
    sed -i 's/6 \* 60 \* 60 \* 1000/Infinity/g' /app/server/lib/SessionManager.js
    sed -i 's/!session.isHibernated && new Date/!session.isHibernated \&\& (!session.connectedWs || session.connectedWs.size === 0) \&\& new Date/g' /app/server/lib/SessionManager.js
    sed -i '/module.exports.remove = async (sessionId, options = {}) => {/a \    try { logger.system(`[DISCONNECT-LOG] 会话彻底移除: ${sessionId}, 原因: ${options.reason || "normal"}`); } catch(e){}' /app/server/lib/SessionManager.js
    echo "[Nexterm-Patch] 2. SessionManager.js 补丁注入成功 (解除 6 小时强杀与会话销毁日志)"
fi

# 3. 修复 ConnectionService.js：注入 SSH 和 SFTP 底层连接保活与断连诊断日志
if [ -f /app/server/lib/ConnectionService.js ]; then
    # SSH 断连日志
    sed -i '/dataSocket\.on("close", () => {/a \            try { logger.system(`[DISCONNECT-LOG] 远程SSH对端关闭(收到EOF): ${entry?.name} (${host}:${port})`); } catch(e){}' /app/server/lib/ConnectionService.js
    sed -i '/dataSocket\.on("error", (err) => {/a \            try { logger.system(`[DISCONNECT-LOG] 远程SSH网络异常: ${entry?.name} (${host}:${port}), 错误: ${err.message}`); } catch(e){}' /app/server/lib/ConnectionService.js

    # SFTP 主动心跳保活与诊断日志
    sed -i '/await sftpClient\.waitForReady();/a \        const sftpKeepAlive = setInterval(() => { if (!dataSocket.destroyed && !sftpClient._closed) { sftpClient.realpath(".").catch(() => {}); try { SessionManager.updateActivity(sessionId); } catch(e){} } }, 25000);' /app/server/lib/ConnectionService.js
    sed -i '/logger\.info("SFTP data connection closed", { sessionId });/i \            clearInterval(sftpKeepAlive); try { logger.system(`[DISCONNECT-LOG] SFTP对端连接断开(EOF): ${entry?.name || sessionId}`); } catch(e){}' /app/server/lib/ConnectionService.js
    sed -i '/logger\.error("SFTP data socket error", { sessionId, error: err\.message });/i \            clearInterval(sftpKeepAlive); try { logger.system(`[DISCONNECT-LOG] SFTP网络异常(Socket Error): ${entry?.name || sessionId}, 错误: ${err.message}`); } catch(e){}' /app/server/lib/ConnectionService.js
    sed -i 's/sftpClient,/sftpClient, keepAliveTimer: sftpKeepAlive,/g' /app/server/lib/ConnectionService.js

    echo "[Nexterm-Patch] 3. ConnectionService.js 补丁注入成功 (SSH & SFTP 底层心跳与日志)"
fi

# 4. 修复 routes/sftpWS.js：注入 SFTP 前端操作活跃刷新与 WebSocket Ping
if [ -f /app/server/routes/sftpWS.js ]; then
    sed -i '/SessionManager\.addWebSocket(sessionId, ws/a \        const sftpWsPing = setInterval(() => { if (ws.readyState === 1) { try { ws.ping(); } catch(e){} } }, 25000);' /app/server/routes/sftpWS.js
    sed -i '/const messageHandler = async (msg) => {/a \            try { SessionManager.updateActivity(sessionId); } catch(e){}' /app/server/routes/sftpWS.js
    sed -i '/ws\.on("close", async () => {/a \            clearInterval(sftpWsPing); try { logger.system(`[DISCONNECT-LOG] 前端SFTP标签页关闭: ${entry?.name || sessionId}`); } catch(e){}' /app/server/routes/sftpWS.js
    echo "[Nexterm-Patch] 4. routes/sftpWS.js 补丁注入成功 (SFTP 前端心跳与活跃刷新)"
fi

echo "[Nexterm-Patch] 所有补丁加载完毕，正在启动 Nexterm..."
exec /bin/sh /app/docker-start.sh
