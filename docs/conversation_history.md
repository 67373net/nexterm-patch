# Nexterm 防断连与稳定性优化排查与对话全记录

本文件完整记录了关于开源容器化终端工具 **Nexterm**（`gnmyt/Nexterm`）远程连接频繁断开、多窗口崩溃等问题的完整排查、分析、方案设计与版本迭代过程。

---

## 一、 问题背景初次排查

### 1.1 用户初次反馈
- **现象描述**：使用 Docker 部署的 Nexterm 远程终端窗口总是会在几个小时后自动关闭，但使用其他终端工具（如 Xshell / PuTTY / Termius）连接同样的远程窗口却能稳定保持数天不掉线。
- **初始要求**：由于是原作者的代码，暂时不要修改任何源码，先深入排查是哪里出了问题，并确认能否在 Nexterm 的 UI 设置界面中解决。

### 1.2 代码库深度排查与根因定位
经过对整个 Nexterm 仓库（前端 React、后端 Node.js 服务端、C 语言编写的底层连接引擎 `nexterm-engine`）的逐行排查，定位到如下关键机制：

1. **罪魁祸首：硬编码的 6 小时强杀定时器 (`server/lib/SessionManager.js:505-516`)**
   ```javascript
   setInterval(() => {
       const sixHoursAgo = new Date(Date.now() - 6 * 60 * 60 * 1000);
       let removed = 0;
       for (const [sessionId, session] of sessions) {
           if (!session.isHibernated && new Date(session.lastActivity) < sixHoursAgo) {
               logger.info("Removing old session", { sessionId });
               module.exports.remove(sessionId);
               removed++;
           }
       }
       if (removed > 0) logger.info(`Cleaned up ${removed} old sessions`);
   }, 30 * 60 * 1000);
   ```
   - 后端每 30 分钟轮询一次所有活动会话，只要 `lastActivity` 距离当前超过 6 小时且未处于“休眠”状态，就会强制销毁连接并向前端发送 WebSocket code 1000。
   - 前端接收到 1000 后直接调用 `disconnectFromServer` 关闭标签页。

2. **缺陷加剧：SSH 模块遗漏活跃时间更新 (`server/hooks/ssh.js`)**
   - 在 RDP/VNC 模块（`hooks/guacamole.js`）中，用户操作时会调用 `SessionManager.updateActivity(sessionId)`。
   - 但在 `hooks/ssh.js` 中，作者**完全遗漏了**这行代码。无论是键盘输入还是终端回显，会话的 `lastActivity` 永远定格在建立连接的第一秒。
   - 结果：**只要连接满 6 小时（6 ~ 6.5 小时），无论用户是否正在使用，会话百分之百被后端强杀**。

3. **设置界面（UI）结论**
   - Nexterm 的 UI 中完全没有开放 KeepAlive 或 Session Timeout 配置，因此**无法在设置界面中彻底解决**。
   - 仅有一个原生特性“休眠 (Hibernate)”（右键标签页选择休眠）可以避开 6 小时清理，但会话会退回后台，无法保持实时前台窗口。

---

## 二、 远程服务器反向心跳讨论

### 2.1 用户提问
- 是不是在远程被连接的 Linux 服务器上配置反向心跳（`ClientAliveInterval`）就能避免这个问题？

### 2.2 分析与答复
- **能解决的部分**：解决了中间防火墙 / NAT 网关在空闲 1~2 小时断开 TCP 连接的问题。
- **不能解决的部分**：无法突破 Nexterm 本身的 6 小时硬核定时器。
  - SSH 心跳包（`keepalive@openssh.com`）由底层 C 引擎 `libssh2` 直接响应，不会作为终端数据流交给 Node.js；
  - 即使交给 Node.js，由于 `hooks/ssh.js` 未调用 `updateActivity`，Nexterm 后端依然认为会话已超时，满 6 小时依然强杀。
  - 因此只改服务端配置，连接的最长寿命被锁死在 **6 ~ 6.5 小时**。

---

## 三、 代码维护方案选型与 Entrypoint Wrapper 设计

### 3.1 用户提问
- 既然是别人的仓库，如果修改了，原作者更新后会不会被覆盖？如何让修改一直有效并跟随作者更新？

### 3.2 方案论证
1. **方案一：Docker 文件挂载覆盖**：维护宿主机独立文件，通过 `-v` 挂载覆盖容器内文件。
2. **方案二：Git 独立分支 + Rebase**：标准开发者工作流。
3. **方案三：Git Patch 补丁**。
4. **方案四：启动脚本热补丁（Entrypoint Wrapper）**：
   - 用户提出：“能否在 docker compose 中加一个启动脚本，先修改源代码中的一部分，再启动 docker”。
   - 确认该方案为最优生产解法：挂载一个 `patch-and-start.sh` 作为容器 entrypoint，容器每次启动时对容器内文件进行动态 `sed` 补丁，随后 `exec /bin/sh docker-start.sh`。即使 `docker compose pull` 拉取官方新镜像，容器启动时也会自动打补丁，永远不怕被覆盖。

---

## 四、 第一版启动脚本发布与多服务器差异排查

### 4.1 第一版脚本实施效果
- 用户实施后反馈：**“现在有些服务器可以连一天以上也不会断，但有一些还是会断”**。
- 这证明 6 小时强杀机制和活跃时间刷新修复完全成功！

### 4.2 为什么部分服务器依然会断？
1. **日志排查盲区**：
   - 官方 Dockerfile 中设置了 `ENV LOG_LEVEL=system`。
   - 原代码中关于连接断开的日志都是 `logger.info` 级别，被全部静音过滤，用户看不到任何断连输出。
2. **服务器环境差异**：
   - 对比发现：`本地内网服务器 (Local Server)`（本地内网）永不断连；
   - `存储服务器 (Server B)`（服务端未开启 `ClientAliveInterval`，默认值为 0，NAT 判定死连接超时）；
   - `公网云服务器 (Cloud Server)`（阿里云公网，云厂商 NAT 网关和安全组空闲清理极其严格，依赖客户端上行心跳）。

### 4.3 另一个 AI 对话记录的技术纠偏
用户分享了与另一个 AI 的排查记录（`260903 145300 SSH连接自动断开排查指南.md`）：
- **另一个 AI 正确之处**：排除了 `$TMOUT`；定位了 `存储服务器 (Server B)` 的 `ClientAliveInterval` 缺失；指出了公网云环境需要客户端主动保活。
- **另一个 AI 严重错误（幻觉）**：
  - 误以为 Nexterm 基于 Node.js 的 `ssh2` 库，建议用 `sed` 替换 `sshClient.connect({...})`。
  - 实际上 Nexterm 底层完全由 C 语言二进制 `nexterm-engine`（基于 `libssh2`）驱动，Node.js 端根本没有 `ssh2` 依赖，该 sed 命令完全无效。

---

## 五、 多窗口与跨设备同步崩溃排查 (Critical Fix)

### 5.1 用户重大故障反馈
- **故障现象**：在浏览器打开两个 Nexterm 窗口（开启“跨设备同步”），关闭其中一个窗口时，**另一个窗口瞬间崩溃，过几秒钟才恢复，并且所有连接全部丢失**！

### 5.2 故障深挖定位
- “过几秒恢复且连接全丢”的本质：**整个容器的 Node.js 进程发生了未捕获异常退出（Crash），触发了 Docker 的 `restart: always` 重启！**
- **崩溃根源**：
  在之前的增强脚本中，我们在 `server/hooks/ssh.js` 的 `ws.on("close")` 中注入了 `logger.system(...)`。
  **然而，Nexterm 原作者在 `server/hooks/ssh.js` 头部根本没有引入 `logger`！**
  当用户关闭任一窗口时，该窗口对应的 WebSocket 关闭，触发：
  `ReferenceError: logger is not defined`
  Node.js 主进程瞬间闪退，容器重启，内存中的所有活跃 SSH 会话全部被销毁！
- 另外，上一版脚本中尝试注入的 `controlPlane.sendSessionResize(..., 0, 0)` 还会把 PTY 窗口大小设为 0x0，也会导致多窗口同步时终端混乱。

### 5.3 终极修复方案
1. 在 `server/hooks/ssh.js` 头部第一行注入 `const logger = require("../utils/logger");`，彻底根除未定义异常；
2. 移除 0x0 窗口缩放，SSH 保活由 Linux 容器内 `sysctls` TCP KeepAlive 和服务端心跳协同保障；
3. 所有注入的日志调用均包裹 `try { ... } catch(e) {}` 实施防御性编程，确保无论发生任何情况绝不让主服务崩溃；
4. 确保在多窗口及跨设备同步场景下，关闭任一窗口，其它窗口毫发无损且持续保持连接。

---

## 六、 最终成果与代码状态

当前最新的补丁脚本已固化在 `patch-and-start.sh` 中，集成了：
- SSH 终端双向活跃度实时刷新；
- 6 小时强杀定时器解除（改用 Infinity + 活跃连接保护）；
- 跨设备同步 / 多窗口防崩溃保护（头文件完整引用 + try-catch 隔离）；
- 完整的底层 SSH 断开原因诊断日志（`[DISCONNECT-LOG]`）。

---

## 七、 SFTP 运行一段时间后自动断开排查与彻底解决 (v1.3.0)

### 7.1 用户反馈
- **现象描述**：除了 SSH 终端，发现 Nexterm 的 SFTP（文件管理器）也会在运行打开一段时间后自动断开。希望排查是否存在该问题，并提供一并解决的新补丁。

### 7.2 SFTP 架构深度剖析与断开根因
通过对 Nexterm 的 SFTP 实现（前端 React `FileRenderer.jsx`、后端路由 `server/routes/sftpWS.js`、连接管理 `server/lib/ConnectionService.js`、FlatBuffers 协议客户端 `server/lib/EngineSftpClient.js` 以及 C 语言引擎 `engine/src/net/sftp.c`）进行逐层排查，发现了导致 SFTP 必然超时的**三大根本缺陷**：

1. **底层 C 引擎严重缺陷：事件循环只监听 `data_fd`，从不轮询 `ssh_sock` (`engine/src/net/sftp.c:792-798`)**
   ```c
   while (session->state == SESSION_STATE_ACTIVE) {
       struct pollfd pfd = { .fd = data_fd, .events = POLLIN };
       int ret = poll(&pfd, 1, 1000);
       ...
   ```
   - 在 SSH 终端模块（`ssh.c`）中，C 引擎使用 `poll` 同时监听内部数据通道 `data_fd` 和底层网络通道 `ssh_sock`，因此服务端有任何网络包都能被及时读取。
   - 但在 SFTP 模块（`sftp.c`）中，作者**仅仅监听了与 Node.js 通信的 `data_fd`**，根本没有监听底层的 `ssh_sock`！
   - **灾难后果**：当用户在 SFTP 界面静止、浏览或阅读代码时，Node.js 没有发送指令，C 引擎就会一直阻塞在 `poll(data_fd)`。
     即使远程 SSH 服务器配置了 `ClientAliveInterval 60` 并主动发送了心跳探测包，这些包堆积在内核套接字缓冲区中，**`sftp.c` 却从未调用 libssh2 去读取它，更无法做出应答**！
     在经过 `ClientAliveCountMax`（默认 3 次 = 3 分钟）后，远程服务器判定客户端失去响应（`Timeout, client not responding`），直接单方面斩断 TCP 连接！
   - 此外，若中间存在 NAT 网关（如阿里云公网 NAT、路由器防火墙），由于双向均无数据流，10~15 分钟后 NAT 映射表项超时失效，连接彻底断死。

2. **Node.js 端缺少 SFTP 应用层心跳与活跃度刷新 (`ConnectionService.js` & `routes/sftpWS.js`)**
   - 在 `ConnectionService.js` 中，原作者为 PVE LXC 连接注入了 30 秒心跳定时器（`dataSocket.write("2")`），但在 `createSFTPConnectionForSession` 中**完全没有设置任何保活定时器**；
   - 在 `server/routes/sftpWS.js` 中，前端用户触发的各种文件操作（列表、重命名、查看、下载等），**从未调用 `SessionManager.updateActivity(sessionId)`**。

3. **浏览器 WebSocket 层可能被反代（Nginx/CF）中断**
   - 前端与后端的 `/api/ws/sftp` WebSocket 连接没有任何 Ping/Pong 心跳，如果用户通过 Nginx（默认 `proxy_read_timeout 60s`）或 Cloudflare 访问，静置 1 分钟即可被前置代理切断。

### 7.3 修复与解决方案 (v1.3.0)
1. **注入 SFTP 底层主动保活心跳 (`ConnectionService.js`)**：
   - 在 SFTP 连接就绪后，启动每 25 秒的保活定时器：执行轻量级 `sftpClient.realpath(".")`；
   - 该请求通过 Node.js -> C 引擎 -> 底层 `libssh2_sftp_realpath` 向远程服务器发送真实的 SFTP 加密控制报文，强制唤醒 C 引擎事件循环，顺带处理服务端堆积的 ClientAlive 探测包；
   - 保证公网云厂商 NAT 网关与防火墙双向流量活跃，彻底避免空闲超时。
2. **注入 SFTP 活跃刷新与 WebSocket 层保活 Ping (`routes/sftpWS.js`)**：
   - 在 WebSocket 消息处理入口注入 `SessionManager.updateActivity(sessionId)`；
   - 每 25 秒向浏览器发送原生 `ws.ping()`，穿透 Nginx 和浏览器后台挂起。
3. **注入 SFTP 底层断连诊断日志**：
   - 当 SFTP 连接因任何外部原因挂断或网络异常时，在日志中明确打出 `[DISCONNECT-LOG] SFTP对端连接断开` 或 `[DISCONNECT-LOG] SFTP网络异常`。
