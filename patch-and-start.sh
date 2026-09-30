#!/bin/sh
set -e

# ==============================================================================
# Nexterm 防断连补丁脚本 (v1.0.0 - 基础版)
#
# 【核心功能说明】
# 1. 修复 SSH 活跃时间刷新缺陷：键盘输入时刷新活跃时间
# 2. 修复 6 小时强杀机制：解除超时限制并增加活跃连接保护
# ==============================================================================

echo "[Nexterm-Patch] 正在检查并应用连接防断开补丁..."

# 1. 修复 SSH 活跃时间刷新缺陷：键盘输入时刷新活跃时间
if [ -f /app/server/hooks/ssh.js ]; then
    sed -i '/SessionManager.markTyping(sessionId, ws);/a \        SessionManager.updateActivity(sessionId);' /app/server/hooks/ssh.js
    sed -i '/ws.readyState === ws.OPEN && ws.send/i \        SessionManager.updateActivity(sessionId);' /app/server/hooks/ssh.js
    echo "[Nexterm-Patch] 1. 已成功为 SSH 注入活跃时间刷新逻辑 (hooks/ssh.js)"
fi

# 2. 修复 6 小时强杀机制：将超时改为 Infinity，且只要浏览器窗口还连着就绝对不杀
if [ -f /app/server/lib/SessionManager.js ]; then
    sed -i 's/6 \* 60 \* 60 \* 1000/Infinity/g' /app/server/lib/SessionManager.js
    sed -i 's/!session.isHibernated && new Date/!session.isHibernated \&\& (!session.connectedWs || session.connectedWs.size === 0) \&\& new Date/g' /app/server/lib/SessionManager.js
    echo "[Nexterm-Patch] 2. 已解除 6 小时强制断连限制并加入活动连接保护 (SessionManager.js)"
fi

echo "[Nexterm-Patch] 补丁注入完成，正在启动 Nexterm..."
exec /bin/sh /app/docker-start.sh
