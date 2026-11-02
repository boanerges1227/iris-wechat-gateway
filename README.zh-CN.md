# iris-wechat-gateway

基于 InterSystems IRIS Interoperability 的企业微信出站适配器。V1 支持通过 Business Operation（BO）发送应用消息及消息推送（原群机器人），消息类型为 `text` 和 `markdown`。

[English](README.md)

## 1. 准备工作

- 可运行 IRIS Interoperability 的环境，以及有权限管理 Production、凭据和 TLS 配置的账号。Docker 示例默认使用 `intersystems/irishealth-community:2026.2`。
- **应用消息**：企业 ID（CorpID）、自建应用的 AgentId 和 Secret；配置应用可见范围及接收成员，并按企业管理后台要求配置实际出口可信 IP。AgentId 与 Secret 应来自同一个应用。
- **消息推送**：在企业微信群创建消息推送，取得 webhook 地址中的 `key`。此通道不使用 access_token；是否有额外 IP 限制应在实际账号环境验证。
- webhook key、应用 Secret 和 access_token 都是凭据，切勿提交到 Git、写入文档或共享完整 URL。

## 2. 启动开发环境

在项目根目录执行：

```bash
docker compose up -d --build
docker compose ps
docker compose logs --tail=100 iris
```

构建会编译 `src/WeChat`、注册并冒烟启动 Demo Production。容器名为 `iris-wechat-gateway`；宿主机端口为管理门户 `52774`、SuperServer `1973`。本地门户地址为 `http://localhost:52774/csp/sys/UtilHome.csp`。开发镜像及配置包含开发用途的账号设置，部署前必须由管理员审核并按环境调整。

进入 WECHAT 命名空间：

```bash
docker exec -it iris-wechat-gateway iris session IRIS -U WECHAT
```

```objectscript
// 查看或启动演示 Production；修改配置后按管理门户提示应用更改。
write ##class(WeChat.Util.Setup).Status()
set sc = ##class(WeChat.Util.Setup).Start()
if $system.Status.IsError(sc) do $system.Status.DisplayError(sc)
```

`Start()` 可能在 Production 已运行时返回状态；先查看 `Status()`。管理门户中选择 `WECHAT` 命名空间，进入 Interoperability 的 Production 配置页，打开 `WeChat.Production.Demo`。该 Production 只含 `SendWeComApp` 和 `SendWeComRobot` 两个 BO，默认指向官方 API，但凭据为空，不能直接发送。

`.env.example` 中只有 `IRIS_IMAGE` 被当前 Compose 文件读取；其中注释掉的 `WECOM_*` 只是配置提示，**不会自动注入 BO**。通过 Production 配置和 Interoperability 凭据设置实际值。

## 3. 配置凭据和 TLS

### 3.1 创建凭据

在管理门户的 Interoperability 凭据管理中创建两个独立凭据，记下凭据 ID：

| 用途 | 凭据内容 | BO 中引用 |
|---|---|---|
| 应用消息 | Password = 自建应用 Secret；UserName 可选填 CorpID | `SecretCredential` |
| 消息推送 | Password = webhook 中的 key | `RobotKeyCredential` |

如果 BO 显式填写凭据 ID，系统不会在凭据不存在时回退到字面量。`CorpId` 显式填写时优先于应用凭据的 UserName。也可以用 `CorpSecret` / `RobotKey` 字面量配置，但应优先使用受访问控制的凭据管理，避免敏感值进入配置导出或日志。

### 3.2 配置出站 TLS

由 IRIS 管理员在安全管理中的 SSL/TLS 配置页面创建或配置一个**客户端**配置，设置适合环境的 CA 信任链、对端证书及主机名验证。将该配置名填入两个 BO 的 Adapter `SSLConfig`。`WeChat.SSL` 是安装辅助方法尝试创建的名称；其具体设置需检查，不能假定可直接用于生产。

分别验证访问 `https://qyapi.weixin.qq.com` 的证书验证和连接；测试不可信证书及主机名不匹配时应失败。不要通过关闭证书验证解决连接问题。IRIS 版本、证书及网络代理不同，具体配置应遵循该环境的 IRIS 文档和安全策略。

## 4. 配置 Production 中的 BO

在 `WeChat.Production.Demo` 的配置页分别选中项目，在其 **Adapter 设置**中填写：

### 4.1 `SendWeComApp`：应用消息

| 设置 | 值与说明 |
|---|---|
| `CorpId` | 企业 CorpID；也可留空并从 `SecretCredential` 的 UserName 读取 |
| `SecretCredential` | 上一步创建的应用凭据 ID，Password 为应用 Secret |
| `CorpSecret` | 未使用凭据 ID 时才填写的应用 Secret |
| `AgentId` | 同一自建应用的正整数 AgentId |
| `ApiBaseUrl` | 正式环境 `https://qyapi.weixin.qq.com`，默认为此值 |
| `SSLConfig` | 已配置并验证的客户端 TLS 配置名；HTTPS 必填 |

应用消息向 `ToUser`、`ToParty`、`ToTag` 中至少一种目标发送。成员应在应用可见范围内且具有所需许可。`@all` 的实际范围以应用配置和平台规则为准。

### 4.2 `SendWeComRobot`：消息推送

| 设置 | 值与说明 |
|---|---|
| `RobotKeyCredential` | 消息推送凭据 ID，Password 为 webhook key |
| `RobotKey` | 未使用凭据 ID 时才填写的 key；只填 key，不填完整 URL |
| `ApiBaseUrl` | 正式环境 `https://qyapi.weixin.qq.com`，默认为此值 |
| `SSLConfig` | 已配置并验证的客户端 TLS 配置名；HTTPS 必填 |

保存配置并按管理门户提示启动或应用更改。Demo 的 Production 定义带空凭据，**健康检查通过只表示 Production 处于运行状态，不证明 BO 已连接微信或消息送达**。

### 4.3 公共设置

| 设置 | 类默认值 | 说明 |
|---|---:|---|
| `Timeout` | 30 秒 | HTTP 连接和请求超时；Demo 配置为 10 秒 |
| `MaxAttempts` | 3 | 发送总尝试上限，包括首次、token 刷新及重试；按需配置，官方系统繁忙建议不超过 3 次 |
| `RetryBaseSeconds` | 1 | 系统繁忙重试的延迟基数；当前实现随尝试次数线性增加 |
| `RetryOnThrottle` | 0 | 是否对 45009 额外启用限流重试；默认关闭，最多一次且计入总次数 |
| `ThrottleWaitSeconds` | 60 | 启用限流重试时等待秒数；须按实际接口限流窗口配置，不能假设一律为一分钟 |
| `TreatEmptyBodyAsAccepted` | 0 | 消息推送收到 2xx 空响应时是否视为受理；默认返回 `unknown`，仅在确认平台行为后才考虑开启 |

## 5. 从业务流程发送

在同一个 Production 的 Business Process 或其他 Business Host 实例方法中调用 `..SendRequestSync`。以下 BO 名称对应 Demo，使用其他 Production 时替换为自己的配置名。示例中的值均为占位符，不要填写凭据。

### 5.1 消息推送

```objectscript
// 在已配置的 Business Process / Business Host 实例方法中执行。
set req = ##class(WeChat.Message.Outbound).%New()
set req.MsgType = "text"
set req.Content = "磁盘使用率 92%"
// 仅 text 可设置提醒列表；markdown 可使用 <@userid>。
do req.MentionedList.SetAt("@all", 1)
set resp = ""
set sc = ..SendRequestSync("SendWeComRobot", req, .resp)
if $isobject(resp) write !,"result=",resp.Result," errcode=",resp.ErrorCode
if $system.Status.IsError(sc) do $system.Status.DisplayError(sc)
```

`Channel` 可留空，由 BO 填入 `wecomrobot`；也可显式设置。调用方传入与 BO 不一致的 Channel 会被拒绝。`MentionedMobileList` 同样仅用于 text；生产系统应保护成员标识和手机号。

### 5.2 应用消息

```objectscript
// AgentId 与 BO 中配置的应用一致，接收人须在应用可见范围内。
set req = ##class(WeChat.Message.Outbound).%New()
set req.MsgType = "text"
set req.Content = "您的任务已完成"
set req.ToUser = "userid1|userid2"
set req.AgentId = 1000002
set req.EnableDuplicateCheck = 1
set req.DuplicateCheckInterval = 1800
set resp = ""
set sc = ..SendRequestSync("SendWeComApp", req, .resp)
if $isobject(resp) write !,"result=",resp.Result," errcode=",resp.ErrorCode
if $system.Status.IsError(sc) do $system.Status.DisplayError(sc)
```

`ToUser`、`ToParty` 和 `ToTag` 使用 `|` 分隔，三者不能同时为空；`ToUser="@all"` 时平台忽略后两者。`Safe` 和 `EnableIdTrans` 仅可用于应用 text。`EnableDuplicateCheck` 及 `DuplicateCheckInterval` 提供平台侧去重选项，不保证端到端恰好一次。使用 `markdown` 时将 `MsgType` 改为 `markdown` 并遵循该通道的字段规则。

上面的调用应放在已编译的业务方法中。直接在 `iris session` 中输入中文可能产生双重编码；消息应来自编译后的类、数据库或互操作消息，并在目标环境验证编码。`WeChat.Util.Setup.SendRobotTest` / `SendAppTest` 是直接 Adapter 辅助方法，不经过 Production，且不提供传入 SSLConfig 的参数，因此不能用于直接测试官方 HTTPS 链路。

## 6. 消息字段与限制

| 通道 | 类型 | `Content` 最大 UTF-8 字节数 | 特殊字段 |
|---|---|---:|---|
| 应用 | `text` | 2048 | 可用 `Safe`、`EnableIdTrans` |
| 应用 | `markdown` | 2048 | 不接受上述 text 专用字段 |
| 消息推送 | `text` | 2048 | 可用 `MentionedList`、`MentionedMobileList` |
| 消息推送 | `markdown` | 4096 | 不接受提醒列表，可用 `<@userid>` |

超长请求在发送前拒绝，不自动拆分。应用消息还可使用 `EnableDuplicateCheck`；消息推送不能使用应用接收人字段。平台受理不保证每个用户最终收到消息；应用消息达到成员频率上限时可能被丢弃。

## 7. 结果、重试与排障

| `SendResponse.Result` | 含义 | 处理建议 |
|---|---|---|
| `accepted` | 当前实现判定平台受理，且无部分失败字段 | 不代表最终送达 |
| `partial` | 平台受理，但部分成员、部门、标签无效或成员无许可 | 检查 `InvalidUser`、`InvalidParty`、`InvalidTag`、`UnlicensedUser` |
| `rejected` | 本地校验或平台明确拒绝 | 查状态及 `ErrorCodePresent`、`ErrorCode`、`ErrorMessage` |
| `unknown` | 无法确认是否已处理 | 默认不自动重发；先确认业务状态，再由调用方决定补发 |

`ErrorCodePresent` 用于区分不存在错误码与错误码 0；还可查看 `HttpStatus`、`Attempts`、`LatencyMs`、`TokenRefreshed` 和 `MessageId`。`RawErrmsg` 是平台文本，可能包含敏感信息，展示或记录前应按环境脱敏。生产消息浏览器的 `Outbound.DisplayText()` 包含收件人和正文前 40 个字符；IRIS 互操作消息持久化及日志访问、保留周期须由管理员按数据敏感度配置。

- `ERROR #6159`：确认所用 BO 的 `SSLConfig` 已填写且是可用的客户端 TLS 配置。
- `60020`：核对应用配置的出口可信 IP、实际 NAT 出口及配置生效情况。
- `301002` / `48002`：核对应用及权限，确保 Secret 来自对应自建应用，而非通讯录同步助手。
- `40014` / `42001`：实现会在尝试预算内条件刷新 token 至多一次。
- `45009`：默认不重试；核对调用频率并由调用方节流。`-1` 按设置进行有界重试。
- 连续凭据失败达到阈值后 token 缓存熔断约一小时；可在修正配置后由具备权限的运维人员使用对应缓存键调用 `WeChat.Data.AccessToken.Reset(cacheKey)` 提前清除。不要记录缓存键中可能包含的企业信息。

## 8. IPM 安装

IPM 包名为 `iris-wechat-gateway`，包版本为 **0.1.0**。在目标 IRIS 命名空间中执行：

```objectscript
zpm "install iris-wechat-gateway"
```

如果目标命名空间尚未配置默认包仓库，可先执行 `zpm "repo -reset-defaults"`，再运行安装命令。IPM 本身需要先在 IRIS 中安装并启用。

也可从 IRIS 进程可访问的项目根目录加载源码：

```objectscript
zpm "load /path/to/iris-wechat-gateway"
```

安装后在目标命名空间配置凭据和客户端 TLS，检查 Production，并按第 2 节启动演示 Production。

## 参考

- [企业微信：发送应用消息](https://developer.work.weixin.qq.com/document/path/90236)
- [企业微信：获取 access_token](https://developer.work.weixin.qq.com/document/path/91039)
- [企业微信：消息推送配置](https://developer.work.weixin.qq.com/document/path/91770)
- [企业微信：全局错误码](https://developer.work.weixin.qq.com/document/path/90313)
- [企业微信：访问频率限制](https://developer.work.weixin.qq.com/document/path/90312)

许可证：MIT。
