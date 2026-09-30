#!/bin/sh
set -e

# ==============================================================================
# Nexterm 增强版防断连与多窗口防崩溃补丁脚本 (v1.2.0)
#
# 【核心功能说明】
# 1. 修复 hooks/ssh.js：引入 logger 并注入活跃刷新与安全断连日志（根除多窗口崩溃）
# 2. 修复 SessionManager.js：解除 6 小时限制，保护当前活跃连接
# 3. 修复 ConnectionService.js：记录真实底层 SSH 的断开原因
# ==============================================================================

echo "[Nexterm-Patch] 正在检查并应用连接防断开与防崩溃补丁..."

# 1. 修复 hooks/ssh.js：引入 logger 并注入活跃刷新与安全断连日志
if [ -f /app/server/hooks/ssh.js ]; then
    # 关键修复：第一行引入 logger，解决 ReferenceError: logger is not defined 导致的多窗口崩溃！
    sed -i '1i const logger = require("../utils/logger");' /app/server/hooks/ssh.js
    
    # 活跃时间刷新（按键输入和远程回显）
    sed -i '/SessionManager.markTyping(sessionId, ws);/a \        SessionManager.updateActivity(sessionId);' /app/server/hooks/ssh.js
    sed -i '/ws.readyState === ws.OPEN && ws.send/i \        SessionManager.updateActivity(sessionId);' /app/server/hooks/ssh.js
    
    # 安全捕获前端窗口关闭事件（包裹 try-catch，绝对防崩溃）
    sed -i '/ws\.on("close", async () => {/a \        try { logger.system(`[DISCONNECT-LOG] 前端标签页关闭: ${entry?.name || sessionId}`); } catch(e){}' /app/server/hooks/ssh.js

    echo "[Nexterm-Patch] 1. hooks/ssh.js 补丁注入成功 (已修复 logger 缺失与多窗口崩溃)"
fi

# 2. 修复 SessionManager.js：解除 6 小时限制，保护当前活跃连接
if [ -f /app/server/lib/SessionManager.js ]; then
    sed -i 's/6 \* 60 \* 60 \* 1000/Infinity/g' /app/server/lib/SessionManager.js
    sed -i 's/!session.isHibernated && new Date/!session.isHibernated \&\& (!session.connectedWs || session.connectedWs.size === 0) \&\& new Date/g' /app/server/lib/SessionManager.js
    sed -i '/module.exports.remove = async (sessionId, options = {}) => {/a \    try { logger.system(`[DISCONNECT-LOG] 会话彻底移除: ${sessionId}, 原因: ${options.reason || "normal"}`); } catch(e){}' /app/server/lib/SessionManager.js
    echo "[Nexterm-Patch] 2. SessionManager.js 补丁注入成功 (解除 6 小时强杀与会话销毁日志)"
fi

# 3. 修复 ConnectionService.js：记录真实底层 SSH 的断开原因
if [ -f /app/server/lib/ConnectionService.js ]; then
    sed -i '/dataSocket\.on("close", () => {/a \            try { logger.system(`[DISCONNECT-LOG] 远程SSH对端关闭(收到EOF): ${entry?.name} (${host}:${port})`); } catch(e){}' /app/server/lib/ConnectionService.js
    sed -i '/dataSocket\.on("error", (err) => {/a \            try { logger.system(`[DISCONNECT-LOG] 远程SSH网络异常(Socket Error): ${entry?.name} (${host}:${port}), 错误: ${err.message}`); } catch(e){}' /app/server/lib/ConnectionService.js
    echo "[Nexterm-Patch] 3. ConnectionService.js 补丁注入成功 (底层断连原因日志)"
fi

echo "[Nexterm-Patch] 所有补丁加载完毕，正在启动 Nexterm..."
exec /bin/sh /app/docker-start.sh
