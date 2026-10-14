# Nexterm 防断连与稳定性增强补丁 (Nexterm Stability & Anti-Disconnect Patch)

本仓库提供针对开源 Web 终端工具 **Nexterm**（`gnmyt/Nexterm`）的官方镜像无侵入式热补丁脚本与排查工具集，旨在彻底解决远程 SSH 终端连接频繁自动断开、6 小时强制断连、多窗口/跨设备同步关闭标签页时服务崩溃重启、以及 **SFTP 文件管理器静置后频繁自动断开**等所有稳定性问题。

---

## 核心解决的问题

1. **彻底解决 SFTP 上传与下载报错 500 (SFTP error) (v1.5.0/v1.5.1 增强)**：
   - 官方为上传/下载设计了独立的辅助传输连接（`getSFTPTransferClient`），但在生成缩略图或完成初次传输后即陷入空闲；由于底层 C 引擎不轮询套接字，远端 SSH 超时切断后 Node.js 无法感知，并在后续上传/下载时复用已死的死连接，触发 `500 (Internal Server Error) Error: SFTP error` 且死连接永久缓存；
   - 补丁自动将辅助传输客户端复用为已通过应用层心跳强保活的主 SFTP 连接，并在传输期间以 `finally` 机制保护传输状态避免心跳包干扰，支持大文件稳定传输与全链路 `[SFTP-TRANSFER]` 审计日志。
2. **彻底解决老旧设备 (iPad Air 2 / Safari 15 / iOS 15) 白屏与全部语法报错 (v1.5.2)**：
   - 官方前端代码在 Vite 打包时保留了 ES2022 的类静态初始化块（`static { ... }`），并在正则字面量中使用了 Safari 16.4 才支持的正则表达式后行断言（Lookbehind：`(?<=...)` 与 `(?<!...)`）；
   - 在 Safari 15.6（iPadOS 15.8.8 最高支持版本）中，遇到静态初始化块会报 `SyntaxError: Unexpected token '{'`；遇到后行断言会误解析为非法命名捕获组并报 `SyntaxError: Invalid regular expression: invalid group specifier name`；
   - 在 v1.5.2 中，启动时自动降级全部 947 处 `static { ... }` 为 Safari 原生支持的自执行字段，并自动消除前端所有文件的 24 处后行断言，使 iPad Air 2 彻底告别白屏与报错，真正做到零配置开箱即用。
3. **彻底解决 SFTP 运行一段时间自动断开 (v1.3.0)**：
   - 官方底层 C 引擎（`engine/src/net/sftp.c`）在空闲时仅轮询内部通道，从不读取底层的 SSH 网络套接字，导致远程服务器发来的心跳包（`ClientAliveInterval`）无法被响应，达到次数后被服务端强制踢出；
   - 补丁在 Node.js 端注入每 25 秒的静默应用层心跳（`realpath(".")`），强制唤醒 C 引擎读写网络流并重置两端空闲计时器，同时增加 WebSocket Ping 心跳穿透 Nginx/Cloudflare。
4. **突破 6 小时强制断开硬编码**：官方代码在 `SessionManager.js` 中每 30 分钟轮询一次，强杀创建满 6 小时的所有会话。
5. **修复 SSH 活跃时间未刷新缺陷**：官方在 `hooks/ssh.js` 中遗漏了 `updateActivity` 调用，导致无论用户是否在使用，连接到达 6 小时必然被杀死。
6. **彻底解决多窗口/跨设备同步崩溃 (Critical Bug)**：修复因原生 `hooks/ssh.js` 缺失 `logger` 引用导致关闭单个标签页触发 `ReferenceError`、进而致使整个容器主进程闪退重启并丢失全部连接的严重缺陷。
7. **注入全协议精准断连与传输诊断日志**：支持 SSH 与 SFTP 的对端 EOF、网络 Socket 重置追踪，统一带有 `[DISCONNECT-LOG]` 与 `[SFTP-TRANSFER]` 标识。
8. **官方镜像无缝跟随升级**：采用 Docker Entrypoint Wrapper（启动包装）机制，每次拉取官方最新镜像启动时自动完成热补丁，完全不影响官方代码更新。

---

## 快速使用说明

### 1. 部署文件结构

建议将本仓库克隆或将脚本放置于与 `docker-compose.yml` 同级目录中：

```text
/opt/docker/nexterm/
├── docker-compose.yml
├── patch-and-start.sh    <-- 本仓库提供的补丁脚本
└── nexterm/              <-- 数据持久化目录 (/app/data)
```

确保赋予脚本执行权限：
```bash
chmod +x patch-and-start.sh
```

### 2. 配置 `docker-compose.yml`

在你的 `docker-compose.yml` 中配置 `entrypoint`、挂载补丁脚本，并加入内核级网络保活参数 `sysctls`：

```yaml
services:
  nexterm:
    image: nexterm/aio:latest
    container_name: nexterm
    restart: always
    ports:
      - 6989:6989
    sysctls:
      # 将 TCP 空闲探测时间缩短为 60 秒，有效穿透云厂商（如阿里云、AWS）及路由器 NAT 防火墙
      - net.ipv4.tcp_keepalive_time=60
      - net.ipv4.tcp_keepalive_intvl=10
      - net.ipv4.tcp_keepalive_probes=3
    environment:
      - ENCRYPTION_KEY=your_encryption_key_here
      - TZ=Asia/Shanghai
    volumes:
      - ./nexterm:/app/data
      - ./patch-and-start.sh:/app/patch-and-start.sh:ro
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
    entrypoint: ["/bin/sh", "/app/patch-and-start.sh"]
```

### 3. 重启容器生效

```bash
docker compose down && docker compose up -d
```

---

## 运维与排查指南

### 1. 实时跟踪断连诊断日志
```bash
docker logs -f nexterm | grep DISCONNECT-LOG
```
典型日志格式示例：
- **SSH 对端正常关闭**：`[DISCONNECT-LOG] 远程SSH对端关闭(收到EOF): MyServer (192.168.1.100:22)`
- **SSH 网络异常中断**：`[DISCONNECT-LOG] 远程SSH网络异常: MyServer (1.2.3.4:22), 错误: read ECONNRESET`
- **SFTP 对端断开**：`[DISCONNECT-LOG] SFTP对端连接断开(EOF): MyServer`
- **前端关闭操作**：`[DISCONNECT-LOG] 前端SSH标签页关闭: MyServer` / `[DISCONNECT-LOG] 前端SFTP标签页关闭: MyServer`

### 2. 检查补丁是否在运行中的容器成功注入
```bash
# 检查 SSH 活跃刷新与崩溃防护
docker exec -it nexterm grep -n "updateActivity" /app/server/hooks/ssh.js

# 检查 SessionManager 6 小时解除
docker exec -it nexterm grep -n "Infinity" /app/server/lib/SessionManager.js

# 检查 SFTP 主动保活心跳
docker exec -it nexterm grep -n "sftpKeepAlive" /app/server/lib/ConnectionService.js

# 检查 SFTP WebSocket 活跃度刷新与 Ping
docker exec -it nexterm grep -n "sftpWsPing" /app/server/routes/sftpWS.js

# 检查前端静态资源 Safari 15 兼容性补丁是否生效
docker exec -it nexterm grep -n "__init" /app/dist/assets/*.js

# 检查 SFTP 上传与下载复用补丁是否生效
docker exec -it nexterm grep -n "getSFTPTransferClient = async" /app/server/lib/ConnectionService.js
```

---

## 版本演进记录 (Changelog)

- **v1.5.0 (Latest)**：
  - **彻底修复 SFTP 上传与下载报错 500 (SFTP error)**：
    - 根因：官方上传/下载使用独立创建的辅助传输连接（`getSFTPTransferClient`），该连接没有保活心跳，闲置后被远程 SSH 服务端踢断；但 Node.js 端因 C 引擎未轮询底层网络套接字而感知不到，下次上传/下载复用已死连接必然抛出 500 `SFTP error` 且死连接永久缓存；
    - 修复：自动将辅助传输客户端复用为主 SFTP 连接，在传输中保护状态并自动刷新活跃时间，注入全链路 `[SFTP-TRANSFER]` 日志。
- **v1.4.0**：
  - **新增老旧设备 (iPad Air 2 / Safari 15 / iOS 15) 前端语法降级兼容补丁**：
    - 针对 iPadOS 15.8.8 (Safari 15.6) 报错 `SyntaxError: Unexpected token '{' (promiseReactionJob)` 白屏问题；
    - 启动时自动扫描 `/app/dist` 静态资源，将 ES2022 `static { ... }` 动态转译为 Safari 14.1+ 即原生支持的静态字段自执行函数（`static __init=(()=>{ ... })()`）；
    - 无需重新配置 Vite 或在本地编译前端代码，容器启动时全自动就地生效。
- **v1.3.0**：
  - **新增 SFTP 全链路防断开体系**：
    - 针对底层 C 引擎不轮询底层套接字的缺陷，在 `ConnectionService.js` 中为 SFTP 注入每 25 秒的主动应用层保活（`realpath(".")`），穿透 NAT 并促使 libssh2 应答服务端心跳；
    - 在 `routes/sftpWS.js` 中注入 WebSocket Ping 心跳与全量文件操作活跃度自动刷新；
    - 补全 SFTP 断开诊断日志与会话生命周期保护。
- **v1.2.0**：
  - 修复多窗口与跨设备同步下关闭任一标签页导致整个服务崩溃重启的致命缺陷（补全 `logger` 引用 + 全链路 try-catch 保护）。
  - 优化日志输出与防崩溃机制。
- **v1.1.0**：
  - 增加对端关闭（EOF）与网络异常（Socket Error）详细诊断日志，前置定位云服务器 NAT 断开原因。
- **v1.0.0**：
  - 首发版本，实现 Entrypoint Wrapper 机制，解除 6 小时强杀，补全 SSH 模块活跃度更新。
