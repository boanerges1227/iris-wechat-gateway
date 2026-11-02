# iris-wechat-gateway

An InterSystems IRIS Interoperability outbound adapter for WeCom. V1 sends `text` and `markdown` through application messages and message push (formerly group robot).

[中文说明](README.zh-CN.md)

## 1. Prerequisites

- IRIS with Interoperability enabled and an administrator who can configure Production, credentials, and TLS. The Docker example defaults to `intersystems/irishealth-community:2026.2`.
- **Application messages:** enterprise CorpID, AgentId and Secret from the same self-built application, application visibility for the recipients, and the actual egress IP configured as required by the enterprise administration settings.
- **Message push:** create a message push in the group and obtain the `key` from its webhook URL. This channel does not use access_token; whether any additional IP restriction applies remains to be verified in the actual account.
- Treat webhook keys, application secrets and tokens as credentials. Do not commit or publish them or a complete credential-bearing URL.

## 2. Start the development environment

From the project root:

```bash
docker compose up -d --build
docker compose ps
docker compose logs --tail=100 iris
```

The build compiles `src/WeChat`, registers the demo Production, and performs a start/stop smoke check. The container is `iris-wechat-gateway`; host ports are `52774` for the management portal and `1973` for SuperServer. The local portal is `http://localhost:52774/csp/sys/UtilHome.csp`. The image and configuration contain development account settings; an administrator must review and adjust them before deployment.

Open an IRIS session in the WECHAT namespace:

```bash
docker exec -it iris-wechat-gateway iris session IRIS -U WECHAT
```

```objectscript
// 查看或启动演示 Production。
write ##class(WeChat.Util.Setup).Status()
set sc = ##class(WeChat.Util.Setup).Start()
if $system.Status.IsError(sc) do $system.Status.DisplayError(sc)
```

Check `Status()` first if the Production may already be running. In the management portal, select namespace `WECHAT`, open the Interoperability Production configuration, and select `WeChat.Production.Demo`. It contains `SendWeComApp` and `SendWeComRobot`, points at the official API by default, and ships with empty credentials.

Only `IRIS_IMAGE` in `.env.example` is consumed by the current Compose file. Commented `WECOM_*` values are examples and **do not configure the BOs automatically**. Configure the Production and Interoperability credentials as described below.

## 3. Configure credentials and TLS

### 3.1 Credentials

Create two separate Interoperability credentials in the management portal and record their IDs:

| Purpose | Credential contents | BO setting |
|---|---|---|
| Application | Password = self-built application Secret; UserName may contain CorpID | `SecretCredential` |
| Message push | Password = webhook key | `RobotKeyCredential` |

An explicitly named but missing credential does not fall back to a literal. An explicit `CorpId` takes precedence over the application credential's UserName. Literal `CorpSecret` and `RobotKey` settings also exist, but managed credentials are preferred to reduce exposure through exports or configuration.

### 3.2 Outbound TLS

Have an IRIS administrator create or configure a **client** SSL/TLS configuration in Security Management, including an appropriate CA trust chain and peer certificate and hostname verification. Set its name as the adapter `SSLConfig` on **both** BOs. `WeChat.SSL` is the name the setup helper attempts to create; inspect its actual settings before use.

Verify the connection to `https://qyapi.weixin.qq.com`; an untrusted certificate or hostname mismatch should fail. Do not disable certificate validation to work around a connection problem. The precise setup depends on the IRIS version, trust store, and network proxy.

## 4. Configure the BOs

In the Demo Production configuration, select each item and set the following **Adapter** properties. Save and apply changes as directed by the management portal.

### 4.1 `SendWeComApp`

| Setting | Value |
|---|---|
| `CorpId` | Enterprise CorpID; alternatively the credential UserName |
| `SecretCredential` | Application credential ID; Password contains Secret |
| `CorpSecret` | Literal Secret only when no credential ID is used |
| `AgentId` | Positive integer AgentId from the same self-built application |
| `ApiBaseUrl` | `https://qyapi.weixin.qq.com` for the real API; this is the default |
| `SSLConfig` | Configured and tested client TLS configuration; required for HTTPS |

At least one of `ToUser`, `ToParty`, and `ToTag` must be supplied on a request. Recipients need the appropriate application visibility and permissions.

### 4.2 `SendWeComRobot`

| Setting | Value |
|---|---|
| `RobotKeyCredential` | Message-push credential ID; Password contains key |
| `RobotKey` | Literal key only when no credential ID is used; do not enter the full URL |
| `ApiBaseUrl` | `https://qyapi.weixin.qq.com` for the real API; this is the default |
| `SSLConfig` | Configured and tested client TLS configuration; required for HTTPS |

A healthy Demo Production only means it is running; it does **not** prove credentials, connectivity, or delivery.

### 4.3 Shared settings

| Setting | Class default | Meaning |
|---|---:|---|
| `Timeout` | 30 seconds | HTTP connect and request timeout; Demo sets 10 |
| `MaxAttempts` | 3 | Total send attempts including first attempt and retries; official system-busy guidance recommends no more than 3 |
| `RetryBaseSeconds` | 1 | Retry delay base; the current implementation increases linearly with the attempt number |
| `RetryOnThrottle` | 0 | Opt in to at most one 45009 retry within the total attempt budget |
| `ThrottleWaitSeconds` | 60 | Wait for the applicable limit window; not every window is one minute |
| `TreatEmptyBodyAsAccepted` | 0 | Message-push 2xx empty body: default `unknown`; consider enabling only after validating the actual platform response |

## 5. Send from a business host

Call `..SendRequestSync` inside an instance method of a Business Process or another Business Host in the same Production. The target names below belong to the Demo; use your own configured names in another Production. These examples contain no credentials.

### 5.1 Message push

```objectscript
// 在 Business Process 或 Business Host 实例方法中执行。
set req = ##class(WeChat.Message.Outbound).%New()
set req.MsgType = "text"
set req.Content = "Disk usage is 92%"
// 仅 text 可设置提醒列表。
do req.MentionedList.SetAt("@all", 1)
set resp = ""
set sc = ..SendRequestSync("SendWeComRobot", req, .resp)
if $isobject(resp) write !,"result=",resp.Result," errcode=",resp.ErrorCode
if $system.Status.IsError(sc) do $system.Status.DisplayError(sc)
```

`Channel` may be left empty for the BO to set to `wecomrobot`, or supplied explicitly. A channel that conflicts with the target BO is rejected. `MentionedMobileList` is also text-only; protect recipient IDs and phone numbers in production.

### 5.2 Application message

```objectscript
// AgentId 与 BO 所配置的应用一致。
set req = ##class(WeChat.Message.Outbound).%New()
set req.MsgType = "text"
set req.Content = "Your task is complete"
set req.ToUser = "userid1|userid2"
set req.AgentId = 1000002
set req.EnableDuplicateCheck = 1
set req.DuplicateCheckInterval = 1800
set resp = ""
set sc = ..SendRequestSync("SendWeComApp", req, .resp)
if $isobject(resp) write !,"result=",resp.Result," errcode=",resp.ErrorCode
if $system.Status.IsError(sc) do $system.Status.DisplayError(sc)
```

Separate `ToUser`, `ToParty`, and `ToTag` values with `|`; at least one is required. The platform ignores the latter two when `ToUser="@all"`. `Safe` and `EnableIdTrans` are application-text-only. The platform duplicate-check option reduces some duplicate risk but is not an end-to-end exactly-once guarantee. Set `MsgType` to `markdown` and follow that channel's field rules for Markdown.

Place these examples in compiled business methods. Typing Chinese directly into `iris session` can lead to double encoding; use a compiled class, database value, or interoperability message and verify encoding in the target environment. `WeChat.Util.Setup.SendRobotTest` and `SendAppTest` call adapters directly, bypass Production, and currently have no SSLConfig argument; they cannot validate the official HTTPS path as written.

## 6. Fields and limits

| Channel | Type | Max `Content` UTF-8 bytes | Special fields |
|---|---|---:|---|
| Application | `text` | 2048 | `Safe`, `EnableIdTrans` |
| Application | `markdown` | 2048 | Rejects those text-only fields |
| Message push | `text` | 2048 | `MentionedList`, `MentionedMobileList` |
| Message push | `markdown` | 4096 | No mention lists; `<@userid>` supported |

Oversized messages are rejected before sending and are not split. An accepted response does not prove final delivery; application messages above the per-recipient frequency limit may be dropped.

## 7. Outcomes and troubleshooting

| `SendResponse.Result` | Meaning | What to do |
|---|---|---|
| `accepted` | Current implementation classified it as accepted, with no partial-failure fields | Acceptance is not final delivery |
| `partial` | Accepted, but some recipients, departments, tags, or licenses failed | Inspect `InvalidUser`, `InvalidParty`, `InvalidTag`, `UnlicensedUser` |
| `rejected` | Local validation or the platform rejected the request | Inspect status, `ErrorCodePresent`, `ErrorCode`, and `ErrorMessage` |
| `unknown` | Cannot determine whether the request was processed | No automatic resend by default; confirm business state before compensating |

`ErrorCodePresent` distinguishes a missing code from zero. Other fields include `HttpStatus`, `Attempts`, `LatencyMs`, `TokenRefreshed`, and `MessageId`. `RawErrmsg` is platform-provided text and may contain sensitive information; sanitize it before displaying or logging. The Production message browser's `Outbound.DisplayText()` includes recipient information and the first 40 characters of content. Administrators must configure access and retention for persisted interoperability messages and logs according to data sensitivity.

- `ERROR #6159`: check the BO's `SSLConfig` and its client TLS configuration.
- `60020`: check the application trusted IP, actual NAT egress and configuration propagation.
- `301002` / `48002`: check application and permissions; use the matching self-built application Secret, not a contacts-sync Secret.
- `40014` / `42001`: the implementation conditionally refreshes the token at most once within the attempt budget.
- `45009`: no retry by default; inspect limits and throttle callers. `-1` uses bounded retries.
- After the credential-failure threshold, token refresh is blocked for about one hour. Once configuration is corrected, an authorized operator may clear it earlier with `WeChat.Data.AccessToken.Reset(cacheKey)` using the appropriate cache key; avoid logging enterprise identifiers contained in the key.

## 8. Tests and IPM

If the development workspace retains `mock/` and `local-only/`, run:

```bash
bash local-only/scripts/e2e.sh --keep
```

The script builds and starts local IRIS and mock, runs the suites, and sends through the adapters directly. `--keep` leaves containers running. To clean up:

```bash
docker compose -f docker-compose.yml -f local-only/docker-compose.mock.yml down
```

The local test assets are not included in the public repository.

`module.xml` describes an IPM module. To load the source, use `zpm "load /path/to/iris-wechat-gateway"` using a project root path visible to the IRIS process. Check classes, credentials, TLS and Production in the target namespace afterwards.

## References

- [WeCom: send application messages](https://developer.work.weixin.qq.com/document/path/90236)
- [WeCom: get access_token](https://developer.work.weixin.qq.com/document/path/91039)
- [WeCom: message push configuration](https://developer.work.weixin.qq.com/document/path/91770)
- [WeCom: global error codes](https://developer.work.weixin.qq.com/document/path/90313)
- [WeCom: rate limits](https://developer.work.weixin.qq.com/document/path/90312)

License: MIT.
