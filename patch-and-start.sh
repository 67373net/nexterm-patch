#!/bin/sh
set -e

# ==============================================================================
# Nexterm 防断连与诊断补丁脚本 (v1.1.0)
#
# 【核心功能说明】
# 1. 修复 SSH 活跃时间刷新缺陷
# 2. 解除 6 小时强杀机制
# 3. 注入 SSH 连接底层断开原因分析日志
# ==============================================================================

echo "[Nexterm-Patch] 正在检查并应用连接防断开与诊断补丁..."

# 1. 修复 SSH 活跃时间刷新缺陷
if [ -f /app/server/hooks/ssh.js ]; then
    sed -i '/SessionManager.markTyping(sessionId, ws);/a \        SessionManager.updateActivity(sessionId);' /app/server/hooks/ssh.js
    sed -i '/ws.readyState === ws.OPEN && ws.send/i \        SessionManager.updateActivity(sessionId);' /app/server/hooks/ssh.js
    echo "[Nexterm-Patch] 1. 已成功为 SSH 注入活跃时间刷新逻辑 (hooks/ssh.js)"
fi

# 2. 修复 6 小时强杀机制
if [ -f /app/server/lib/SessionManager.js ]; then
    sed -i 's/6 \* 60 \* 60 \* 1000/Infinity/g' /app/server/lib/SessionManager.js
    sed -i 's/!session.isHibernated && new Date/!session.isHibernated \&\& (!session.connectedWs || session.connectedWs.size === 0) \&\& new Date/g' /app/server/lib/SessionManager.js
    sed -i '/module.exports.remove = async (sessionId, options = {}) => {/a \    try { logger.system(`[DISCONNECT-LOG] 会话彻底移除: ${sessionId}, 原因: ${options.reason || "normal"}`); } catch(e){}' /app/server/lib/SessionManager.js
    echo "[Nexterm-Patch] 2. 已解除 6 小时强制断连限制并加入活动连接保护 (SessionManager.js)"
fi

# 3. 注入 SSH 连接底层断开原因分析日志
if [ -f /app/server/lib/ConnectionService.js ]; then
    sed -i '/dataSocket\.on("close", () => {/a \            try { logger.system(`[DISCONNECT-LOG] 远程SSH对端关闭(收到EOF): ${entry?.name} (${host}:${port})`); } catch(e){}' /app/server/lib/ConnectionService.js
    sed -i '/dataSocket\.on("error", (err) => {/a \            try { logger.system(`[DISCONNECT-LOG] 远程SSH网络异常: ${entry?.name} (${host}:${port}), 错误: ${err.message}`); } catch(e){}' /app/server/lib/ConnectionService.js
    echo "[Nexterm-Patch] 3. 底层精确断连日志注入成功 (ConnectionService.js)"
fi

echo "[Nexterm-Patch] 补丁注入完成，正在启动 Nexterm..."
exec /bin/sh /app/docker-start.sh
