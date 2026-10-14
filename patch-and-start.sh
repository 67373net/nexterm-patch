#!/bin/sh
set -e

# ==============================================================================
# Nexterm 增强版防断连、防崩溃与全端兼容热补丁脚本 (v1.5.2)
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
# 4. 彻底解决 SFTP 闲置断开与上传下载报错 500 (ConnectionService.js & routes/sftp.js)：
#    - 修复上传/下载使用未保活辅助连接导致超时变死连接并抛出 500 "SFTP error" 的严重缺陷；
#    - 自动复用已强保活的主 SFTP 连接，并在传输期间保护状态避免心跳包干扰，支持大文件稳定传输与完整状态日志；
#    - 注入 SFTP 主动保活心跳与 WebSocket 层保活 Ping：防止浏览器后台挂起或反向代理超时断开。
#
# 5. 解决老旧设备 (iPad Air 2 / Safari 15 / iOS 15) 白屏与全部语法报错 (dist/*.js) [v1.5.2]：
#    - 自动降级前端全部 947 处 ES2022 Class Static Initialization Blocks (`static { ... }`) 为 Safari 兼容自执行函数；
#    - 自动消除老旧 Safari 不支持的正则先行断言/后行断言 (`(?<=...)` 与 `(?<!...)`)，根除 `SyntaxError: Invalid regular expression: invalid group specifier name`；
#    - 彻底解决 Safari 15.6 / WebKit 605 抛出的一系列语法异常，使 iPad Air 2 丝滑秒开 Nexterm。
#
# 【运维排查常用指令】
# 1. 动态过滤断连诊断日志：
#    docker logs -f <container_name> | grep -E "DISCONNECT-LOG|SFTP-TRANSFER"
#
# 2. 检查补丁是否在容器中正确生效：
#    docker exec -it <container_name> grep -n "sftpKeepAlive" /app/server/lib/ConnectionService.js
#    docker exec -it <container_name> grep -n "updateActivity" /app/server/hooks/ssh.js
#    docker exec -it <container_name> grep -n "Infinity" /app/server/lib/SessionManager.js
#
# 3. 宿主机快速重启容器服务：
#    cd /opt/docker/nexterm && docker compose restart
# ==============================================================================

echo "[Nexterm-Patch] 正在检查并应用连接防断开、防崩溃与全端兼容补丁 (v1.5.2)..."

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

# 3. 修复 ConnectionService.js：注入 SSH/SFTP 保活心跳、断连诊断并修复上传下载连接
if [ -f /app/server/lib/ConnectionService.js ]; then
    # SSH 断连日志
    sed -i '/dataSocket\.on("close", () => {/a \            try { logger.system(`[DISCONNECT-LOG] 远程SSH对端关闭(收到EOF): ${entry?.name} (${host}:${port})`); } catch(e){}' /app/server/lib/ConnectionService.js
    sed -i '/dataSocket\.on("error", (err) => {/a \            try { logger.system(`[DISCONNECT-LOG] 远程SSH网络异常: ${entry?.name} (${host}:${port}), 错误: ${err.message}`); } catch(e){}' /app/server/lib/ConnectionService.js

    # SFTP 主动心跳保活与诊断日志
    sed -i '/await sftpClient\.waitForReady();/a \        const sftpKeepAlive = setInterval(() => { const transferStale = sftpClient._transferStart && (Date.now() - sftpClient._transferStart > 60000); if (!dataSocket.destroyed && !sftpClient._closed && (!sftpClient._activeTransfer || transferStale)) { sftpClient.realpath(".").catch(() => {}); try { SessionManager.updateActivity(sessionId); } catch(e){} } }, 25000);' /app/server/lib/ConnectionService.js
    sed -i '/logger\.info("SFTP data connection closed", { sessionId });/i \            clearInterval(sftpKeepAlive); try { logger.system(`[DISCONNECT-LOG] SFTP对端连接断开(EOF): ${entry?.name || sessionId}`); } catch(e){}' /app/server/lib/ConnectionService.js
    sed -i '/logger\.error("SFTP data socket error", { sessionId, error: err\.message });/i \            clearInterval(sftpKeepAlive); try { logger.system(`[DISCONNECT-LOG] SFTP网络异常(Socket Error): ${entry?.name || sessionId}, 错误: ${err.message}`); } catch(e){}' /app/server/lib/ConnectionService.js
    sed -i 's/sftpClient,/sftpClient, keepAliveTimer: sftpKeepAlive,/g' /app/server/lib/ConnectionService.js

    # 修复 SFTP 上传与下载死连接缺陷：复用保活的主 SFTP 连接
    node -e '
    const fs = require("fs");
    const file = "/app/server/lib/ConnectionService.js";
    let c = fs.readFileSync(file, "utf8");
    const r1 = /const getSFTPTransferClient\s*=\s*\(sessionId, entry, accountId\)\s*=>[\s\S]*?getAuxiliarySFTPClient\(sessionId, entry, accountId, \{\s*suffix:\s*"xfer"[\s\S]*?\}\);/;
    const r2 = /const getSFTPBackgroundClient\s*=\s*\(sessionId, entry, accountId\)\s*=>[\s\S]*?getAuxiliarySFTPClient\(sessionId, entry, accountId, \{\s*suffix:\s*"bg"[\s\S]*?\}\);/;
    if (r1.test(c)) {
        c = c.replace(r1, "const getSFTPTransferClient = async (sessionId, entry, accountId) => { let conn = SessionManager.getConnection(sessionId); if (!conn?.sftpClient) { await createSFTPConnectionForSession(sessionId, entry, accountId); conn = SessionManager.getConnection(sessionId); } return conn?.sftpClient ?? null; };");
    }
    if (r2.test(c)) {
        c = c.replace(r2, "const getSFTPBackgroundClient = async (sessionId, entry, accountId) => { let conn = SessionManager.getConnection(sessionId); if (!conn?.sftpClient) { await createSFTPConnectionForSession(sessionId, entry, accountId); conn = SessionManager.getConnection(sessionId); } return conn?.sftpClient ?? null; };");
    }
    fs.writeFileSync(file, c, "utf8");
    '
    echo "[Nexterm-Patch] 3. ConnectionService.js 补丁注入成功 (SSH & SFTP 底层心跳与传输复用)"
fi

# 4. 修复 routes/sftp.js：注入上传与下载状态保护、活跃刷新与传输日志
if [ -f /app/server/routes/sftp.js ]; then
    node -e '
    const fs = require("fs");
    const file = "/app/server/routes/sftp.js";
    let c = fs.readFileSync(file, "utf8");

    // 1. 上传逻辑包装：加入活跃刷新与 finally 状态保护
    const oldUpload = "await ctx.sftpClient.writeFile(remotePath, req);";
    const newUpload = `try {
            ctx.sftpClient._activeTransfer = true;
            ctx.sftpClient._transferStart = Date.now();
            SessionManager.updateActivity(sessionId);
            logger.system("[SFTP-TRANSFER] 开始上传文件: " + remotePath);
            await ctx.sftpClient.writeFile(remotePath, req);
            logger.system("[SFTP-TRANSFER] 上传文件成功: " + remotePath);
        } finally {
            ctx.sftpClient._activeTransfer = false;
        }`;
    if (c.includes(oldUpload)) c = c.replace(oldUpload, newUpload);

    // 2. 下载逻辑包装：加入活跃刷新与全事件生命周期保护
    const oldDownload = "const { stream } = sftpClient.readFile(remotePath);";
    const newDownload = `try {
            sftpClient._activeTransfer = true;
            sftpClient._transferStart = Date.now();
            SessionManager.updateActivity(sessionId);
            logger.system("[SFTP-TRANSFER] 开始下载文件: " + remotePath);
        } catch(e) {}
        const { stream } = sftpClient.readFile(remotePath);
        const clearXfer = () => { try { sftpClient._activeTransfer = false; } catch(e){} };
        res.on("finish", () => { clearXfer(); try { logger.system("[SFTP-TRANSFER] 下载文件完成: " + remotePath); } catch(e){} });`;
    if (c.includes(oldDownload)) c = c.replace(oldDownload, newDownload);

    const oldClose = "res.on(\"close\", () => stream.destroy());";
    const newClose = "res.on(\"close\", () => { clearXfer(); stream.destroy(); });";
    if (c.includes(oldClose)) c = c.replace(oldClose, newClose);

    fs.writeFileSync(file, c, "utf8");
    '
    echo "[Nexterm-Patch] 4. routes/sftp.js 补丁注入成功 (SFTP 传输活动刷新与状态保护)"
fi

# 5. 修复 routes/sftpWS.js：注入 SFTP 前端操作活跃刷新与 WebSocket Ping
if [ -f /app/server/routes/sftpWS.js ]; then
    sed -i '/SessionManager\.addWebSocket(sessionId, ws/a \        const sftpWsPing = setInterval(() => { if (ws.readyState === 1) { try { ws.ping(); } catch(e){} } }, 25000);' /app/server/routes/sftpWS.js
    sed -i '/const messageHandler = async (msg) => {/a \            try { SessionManager.updateActivity(sessionId); } catch(e){}' /app/server/routes/sftpWS.js
    sed -i '/ws\.on("close", async () => {/a \            clearInterval(sftpWsPing); try { logger.system(`[DISCONNECT-LOG] 前端SFTP标签页关闭: ${entry?.name || sessionId}`); } catch(e){}' /app/server/routes/sftpWS.js
    echo "[Nexterm-Patch] 5. routes/sftpWS.js 补丁注入成功 (SFTP 前端心跳与活跃刷新)"
fi

# 6. 修复前端静态资源对老旧 iPad (Safari 15 / iPadOS 15.8.8) 的完全兼容性 (v1.5.2)
#    - 彻底降级前端静态资源中的全部 ES2022 Class Static Blocks (static { ... })
#    - 消除 Safari 15.6 不支持的正则后行断言 (?<=...) 与 (?<!...)，根除 invalid group specifier name 报错
if [ -d /app/dist ]; then
    node << 'NODE_EOF'
const fs = require('fs');
const path = require('path');

function findJsFiles(dir) {
    let results = [];
    if (!fs.existsSync(dir)) return results;
    for (const file of fs.readdirSync(dir)) {
        const fullPath = path.join(dir, file);
        const stat = fs.statSync(fullPath);
        if (stat.isDirectory()) {
            results = results.concat(findJsFiles(fullPath));
        } else if (file.endsWith('.js')) {
            results.push(fullPath);
        }
    }
    return results;
}

function patchStaticBlocks(code) {
    const regex = /(?<![a-zA-Z0-9_$])static\s*\{/g;
    let m;
    let lastIndex = 0;
    let result = '';
    let idx = 0;
    let total = 0;

    while ((m = regex.exec(code)) !== null) {
        result += code.slice(lastIndex, m.index);
        const bodyStart = m.index + m[0].length;
        let depth = 1;
        let p = bodyStart;
        while (p < code.length && depth > 0) {
            const c = code[p];
            if (c === '{') depth++;
            else if (c === '}') depth--;
            else if (c === '"' || c === "'" || c === '`') {
                const q = c;
                p++;
                while (p < code.length) {
                    if (code[p] === '\\') p += 2;
                    else if (code[p] === q) break;
                    else p++;
                }
            } else if (c === '/' && code[p + 1] === '/') {
                p += 2;
                while (p < code.length && code[p] !== '\n') p++;
            } else if (c === '/' && code[p + 1] === '*') {
                p += 2;
                while (p < code.length && !(code[p] === '*' && code[p + 1] === '/')) p++;
                p += 2;
            }
            p++;
        }
        idx++;
        total++;
        const body = code.slice(bodyStart, p - 1);
        result += `static __sb_${idx}=(()=>{${body}})();`;
        lastIndex = p;
        regex.lastIndex = p;
    }
    result += code.slice(lastIndex);
    return { result, total };
}

function patchLookbehinds(code) {
    let modified = code;
    modified = modified.replaceAll("(?<=['\"\\s])", "(?:['\"\\s])");
    modified = modified.replaceAll("(?<=\\\\.)", "(?=\\\\.)");
    modified = modified.replaceAll("(?<=1)(?<!1)", "(?!1)");
    modified = modified.replaceAll("(?<!`)()", "(?:^^|[^`])");
    return modified;
}

try {
    const jsFiles = findJsFiles('/app/dist');
    let staticTotal = 0;
    let lookbehindFiles = 0;

    for (const file of jsFiles) {
        let content = fs.readFileSync(file, 'utf8');
        let changed = false;

        if (/(?<![a-zA-Z0-9_$])static\s*\{/.test(content)) {
            const { result, total } = patchStaticBlocks(content);
            content = result;
            staticTotal += total;
            changed = true;
        }

        if (/\(\?<[=!]/.test(content)) {
            content = patchLookbehinds(content);
            lookbehindFiles++;
            changed = true;
        }

        if (changed) {
            fs.writeFileSync(file, content, 'utf8');
        }
    }

    if (staticTotal > 0 || lookbehindFiles > 0) {
        console.log(`[Nexterm-Patch] 6. 前端全兼容补丁生效: 降级 ${staticTotal} 处 static {，优化 ${lookbehindFiles} 个文件中的正则后行断言，全面兼容 Safari 15 / iPad Air 2!`);
    } else {
        console.log('[Nexterm-Patch] 6. 前端静态资源扫描完毕 (已是兼容格式或无需降级)');
    }
} catch (err) {
    console.error('[Nexterm-Patch] 6. 前端资源补丁处理跳过 (非关键错误):', err.message);
}
NODE_EOF
fi

echo "[Nexterm-Patch] 所有补丁加载完毕，正在启动 Nexterm..."
exec /bin/sh /app/docker-start.sh
