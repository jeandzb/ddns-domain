# 阿里云单域名 DDNS 使用手册

## 1. 功能说明

这是一个基于 `bash + systemd timer` 的轻量 DDNS 方案，支持：

- 单域名
- 通过顶层变量切换使用 `IPv4` 或 `IPv6`
- 自动检测本机 IP 是否可用
- 自动创建解析记录
- 自动更新已有解析记录
- 当前网络暂时没有目标 IP 时，不报错、不删记录，等待下一轮自动恢复
- 通过 systemd 定时执行，轻量、稳定、易维护

---

## 2. 适用场景

适合这类需求：

- Linux 主机
- 阿里云 DNS 解析
- 家宽 / 动态公网 IP / 动态 IPv6 前缀
- 只需要维护一个域名记录
- 不需要多域名批量同步
- 不需要 IPv4/IPv6 fallback

---

## 3. 依赖要求

系统需要具备以下命令：

- `bash`
- `curl`
- `ip`
- `openssl`
- `awk`
- `sed`
- `grep`
- `flock`
- `systemd`

一般常见 Linux 发行版默认都有这些组件。

---

## 4. 脚本说明

脚本文件建议保存为：

```bash
/usr/local/bin/alidns-ddns.sh
```

脚本的核心配置项如下：

```bash
ACCESS_KEY_ID="your_access_key_id"
ACCESS_KEY_SECRET="your_access_key_secret"

DOMAIN="example.com"
RR="home"
IP_VERSION="6"
TTL="600"
IFACE=""
```

### 参数解释

#### `ACCESS_KEY_ID`
阿里云 AccessKey ID。

#### `ACCESS_KEY_SECRET`
阿里云 AccessKey Secret。

建议使用 RAM 子账号，不要直接使用主账号密钥。

#### `DOMAIN`
主域名，例如：

```bash
example.com
```

#### `RR`
主机记录：

- `home` 表示 `home.example.com`
- `@` 表示根域名 `example.com`

#### `IP_VERSION`
控制当前脚本维护哪种解析记录：

- `4`：维护 `A` 记录
- `6`：维护 `AAAA` 记录

这是脚本最上层的总开关。

#### `TTL`
解析记录 TTL，单位秒。

#### `IFACE`
指定网卡名，例如：

```bash
IFACE="eth0"
```

留空则自动从全局地址中取第一个可用地址。  
如果机器有多个网卡，建议明确指定。

---

## 5. 工作逻辑

### 当 `IP_VERSION="4"` 时
脚本会：

1. 获取本机全局 IPv4
2. 查询阿里云对应 `A` 记录
3. 若记录不存在则自动创建
4. 若记录存在且 IP 不同则更新
5. 若 IP 未变化则不操作

### 当 `IP_VERSION="6"` 时
脚本会：

1. 获取本机稳定的全局 IPv6
2. 自动过滤 `temporary / deprecated / tentative`
3. 查询阿里云对应 `AAAA` 记录
4. 若记录不存在则自动创建
5. 若记录存在且 IP 不同则更新
6. 若 IP 未变化则不操作

### 当前网络没有目标 IP 时
例如：

- 当前没有公网 IPv4
- 当前网络暂时没有 IPv6
- IPv6 还没协商完成

脚本会直接跳过本轮，不报错，不删除现有 DNS 记录。  
等下一轮检测到 IP 可用时，会自动创建或更新解析。

---

## 6. 部署步骤

### 第一步：保存脚本

将脚本保存为：

```bash
sudo vim /usr/local/bin/alidns-ddns.sh
```

粘贴脚本内容后保存。

### 第二步：赋予执行权限

```bash
sudo chmod 755 /usr/local/bin/alidns-ddns.sh
```

如果脚本是从 Windows 编辑器复制过来的，建议顺手清理换行：

```bash
sudo sed -i 's/\r$//' /usr/local/bin/alidns-ddns.sh
```

### 第三步：先手工测试

```bash
sudo /usr/local/bin/alidns-ddns.sh
```

正常时你会看到类似日志：

```text
[2026-03-31 11:00:00] created home.example.com AAAA -> 2408:xxxx::1234
```

或：

```text
[2026-03-31 11:00:00] unchanged home.example.com AAAA: 2408:xxxx::1234
```

---

## 7. 配置 systemd 服务

创建服务文件：

```bash
sudo vim /etc/systemd/system/alidns-ddns.service
```

内容如下：

```ini
[Unit]
Description=Alibaba Cloud DDNS updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/bin/alidns-ddns.sh
```

这里显式使用 `/bin/bash`，可以减少 shebang 或执行环境问题。

---

## 8. 配置 systemd 定时器

创建定时器文件：

```bash
sudo nano /etc/systemd/system/alidns-ddns.timer
```

内容如下：

```ini
[Unit]
Description=Run Alibaba Cloud DDNS updater periodically

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=alidns-ddns.service

[Install]
WantedBy=timers.target
```

说明：

- 开机 20 秒后执行一次
- 之后每 30 秒执行一次
- 若你不需要这么快，可以改成 `60s`

---

## 9. 启动服务

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now alidns-ddns.timer
sudo systemctl start alidns-ddns.service
```

查看定时器状态：

```bash
systemctl status alidns-ddns.timer
```

查看服务日志：

```bash
journalctl -u alidns-ddns.service -f
```

---

## 10. 常见输出说明

### 1）没有可用 IP

```text
[2026-03-31 11:00:00] no usable IPv6 found, skip
```

表示当前没拿到目标 IP。  
这是正常状态，不是故障。

### 2）自动创建成功

```text
[2026-03-31 11:00:00] created home.example.com AAAA -> 2408:xxxx::1234
```

表示阿里云上原本没有对应记录，脚本已自动创建。

### 3）无需更新

```text
[2026-03-31 11:00:00] unchanged home.example.com AAAA: 2408:xxxx::1234
```

表示云端记录和本机 IP 一致。

### 4）更新成功

```text
[2026-03-31 11:00:00] updated home.example.com AAAA: 2408:xxxx::5678 -> 2408:xxxx::1234
```

表示云端记录已被刷新为当前 IP。

### 5）API 调用失败

```text
[2026-03-31 11:00:00] DescribeDomainRecords failed, skip this round
```

或：

```text
[2026-03-31 11:00:00] AddDomainRecord failed
```

表示本轮调用失败。  
脚本不会崩溃，下一轮会继续尝试。

---

## 11. 切换 IPv4 / IPv6

只需要修改脚本中的：

```bash
IP_VERSION="6"
```

可选值：

```bash
IP_VERSION="4"
```

或：

```bash
IP_VERSION="6"
```

对应关系：

- `4` -> 维护阿里云 `A` 记录
- `6` -> 维护阿里云 `AAAA` 记录

修改后重启服务即可：

```bash
sudo systemctl restart alidns-ddns.service
```

---

## 12. 安全建议

### 1）使用 RAM 子账号
建议为这个脚本单独创建一个 RAM 子账号，仅授予云解析相关权限。

### 2）不要把脚本暴露给普通用户
建议：

- 脚本仅 root 可写
- AccessKey 不要放进公开仓库

### 3）日志中不会打印密钥
当前脚本不会主动输出 AK/SK，但你仍应妥善保管脚本文件权限。

---

## 13. 排错建议

### 问题 1：systemd 报 `203/EXEC`
常见原因：

- 脚本不存在
- 没执行权限
- 换行是 CRLF
- `ExecStart` 写错

检查：

```bash
ls -l /usr/local/bin/alidns-ddns.sh
head -n 1 /usr/local/bin/alidns-ddns.sh | cat -A
sudo sed -i 's/\r$//' /usr/local/bin/alidns-ddns.sh
sudo chmod 755 /usr/local/bin/alidns-ddns.sh
```

### 问题 2：一直提示没有 IPv6
检查：

```bash
ip -6 addr show scope global
```

如果没有全局 IPv6，脚本会一直跳过。  
这不是脚本故障，而是当前网络未提供可用 IPv6。

### 问题 3：多网卡拿错地址
设置：

```bash
IFACE="eth0"
```

指定正确网卡。

---

## 14. 卸载方法

停止并禁用定时器：

```bash
sudo systemctl disable --now alidns-ddns.timer
```

删除服务与定时器：

```bash
sudo rm -f /etc/systemd/system/alidns-ddns.service
sudo rm -f /etc/systemd/system/alidns-ddns.timer
sudo systemctl daemon-reload
```

删除脚本：

```bash
sudo rm -f /usr/local/bin/alidns-ddns.sh
```

---

## 15. 最小部署清单

你最终只需要这三样：

- `/usr/local/bin/alidns-ddns.sh`
- `/etc/systemd/system/alidns-ddns.service`
- `/etc/systemd/system/alidns-ddns.timer`

这样就能完成单域名、单协议版本的阿里云 DDNS 自动维护。
