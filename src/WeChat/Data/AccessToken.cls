/// 企业微信应用消息通道的 access_token 缓存。
/// 缓存依据（官方原文）：“不能频繁调用gettoken接口，否则会受到频率拦截”；
/// “企业微信可能会出于运营需要，提前使access_token失效，开发者应实现access_token
/// 失效时重新获取的逻辑”。企业微信没有 stable_token，公众号规则不可照搬。
/// “每个应用的access_token是彼此独立的，所以进行缓存时需要区分应用来进行存储”：
/// 缓存 key 含 corpid、agentid 与 secret 指纹（secret 本身从不存储，轮换即自然失效）。
/// 刷新在锁内单飞（single-flight），HTTP 调用由执行方发起，本类可离线测试。
/// “如果应用的secret错误多次，会导致同一个IP被禁用一小时”——连续 MAXSECRETFAILURES
/// 次凭据错误后熔断拒绝刷新，须显式 Reset()。Token 存 1024 字符，官方上限 512 字节；
/// 其值绝不可出现在日志、异常消息或返回给客户端的内容中。
Class WeChat.Data.AccessToken Extends %Persistent
{

/// 一条缓存 token 的复合标识。
Property CacheKey As %String(MAXLEN = 400) [ Required ];

Property Channel As %String(MAXLEN = 20);

Property CorpId As %String(MAXLEN = 100);

/// 保留在 key 中：token 只对签发它的应用有效，与别的 agentid 混用必然
/// 产生 errcode 301002。
Property AgentId As %Integer;

/// 互操作凭据 ID，用于代替明文 secret 时使用。
Property CredentialId As %String(MAXLEN = 100);

/// secret 的截断 SHA-256：轮换 secret 即使缓存失效，且无需存储或记录 secret。
Property SecretFingerprint As %String(MAXLEN = 16);

/// 签发 token 对应的 API base URL，使测试端点与生产端点不共用缓存。
Property ApiEnv As %String(MAXLEN = 300);

/// 官方最大值为 512 字节；1024 留有富余。
Property Token As %String(MAXLEN = 1024);

Property IssuedAt As %BigInt;

/// 自该纪元秒起 token 不再视为可用。
Property ExpiresAt As %BigInt;

/// 单调递增；支持条件失效，防止迟到的调用方丢弃已被其他进程替换的 token。
Property Version As %BigInt [ InitialExpression = 0 ];

/// 连续的凭据类失败次数（40001 / 40091 / 45031）。
Property SecretFailures As %Integer [ InitialExpression = 0 ];

/// 拒绝刷新的截止时间（纪元秒）。
Property BlockedUntil As %BigInt [ InitialExpression = 0 ];

Property LastErrcode As %Integer;

Property LastErrorAt As %BigInt;

Index KeyIndex On CacheKey [ Unique ];

/// 在过期前多久尝试刷新。
Parameter REFRESHWINDOW = 300;

/// 熔断器开启前容忍的凭据失败次数。
Parameter MAXSECRETFAILURES = 3;

/// 熔断保持开启的时长，对应官方的一小时 IP 封禁。
Parameter BLOCKSECONDS = 3600;

/// 另一进程刷新时的锁等待时间。
Parameter LOCKTIMEOUT = 10;

/// 构造复合缓存 key。secret 仅以指纹表示。
ClassMethod KeyFor(pChannel As %String, pCorpId As %String, pAgentId As %Integer, pCredentialId As %String, pSecretFingerprint As %String, pApiEnv As %String) As %String
{
	Quit $ZConvert(pChannel, "L") _ "|" _ pCorpId _ "|" _ (pAgentId + 0) _ "|" _ pCredentialId _ "|" _ pSecretFingerprint _ "|" _ pApiEnv
}

/// 打开已有行，或返回一个未保存的新对象。从不抛出异常。
ClassMethod Open(pKey As %String) As WeChat.Data.AccessToken
{
	Set tObj = ""
	Try {
		If ..KeyIndexExists(pKey) Set tObj = ..KeyIndexOpen(pKey)
	} Catch ex {
		Set tObj = ""
	}
	If $IsObject(tObj) Quit tObj
	Set tNew = ..%New()
	Set tNew.CacheKey = pKey
	Quit tNew
}

/// 该行存在于数据库时返回真。
ClassMethod IsPersisted(pKey As %String) As %Boolean
{
	Set tOut = 0
	Try {
		Set tOut = ..KeyIndexExists(pKey)
	} Catch ex {
		Set tOut = 0
	}
	Quit tOut
}

/// 返回仍然有效的缓存 token，不获取刷新锁；需要刷新时输出 ""。
/// 同时报告当前 Version，供调用方稍后条件失效。
ClassMethod Cached(pKey As %String, Output pVersion As %BigInt) As %String
{
	Set pVersion = 0
	Set tObj = ..Open(pKey)
	If '$IsObject(tObj) Quit ""
	Set pVersion = tObj.Version
	Set tNow = ##class(WeChat.Util.Http).EpochNow()
	If tObj.Token = "" Quit ""
	If tObj.BlockedUntil > tNow Quit ""
	If (tObj.ExpiresAt - ..#REFRESHWINDOW) <= tNow Quit ""
	Quit tObj.Token
}

/// 尝试成为 pKey 的唯一刷新进程：返回 1 表示已持有刷新权，此后必须且只能调用
/// StoreRefreshed / StoreFailure / AbortRefresh 之一；返回 0 表示无需刷新（pToken 携带可用值）或被拒绝，原因见 pSC。
ClassMethod TryBeginRefresh(pKey As %String, Output pToken As %String, Output pVersion As %BigInt, Output pSC As %Status) As %Boolean
{
	Set pToken = "", pVersion = 0, pSC = $$$OK

	// 锁外快速路径。
	Set pToken = ..Cached(pKey, .pVersion)
	If pToken '= "" Quit 0

	Lock +^WeChatTokenLock(pKey):..#LOCKTIMEOUT
	If '$Test {
		// 竞争进程持锁。重新读取：它可能已完成刷新。
		Set pToken = ..Cached(pKey, .pVersion)
		If pToken '= "" Quit 0
		Set pSC = $$$ERROR($$$GeneralError, "Another process is refreshing the WeCom access_token and did not finish within "_..#LOCKTIMEOUT_"s; retry later")
		Quit 0
	}

	Set tObj = ..Open(pKey)
	Set pVersion = tObj.Version
	Set tNow = ##class(WeChat.Util.Http).EpochNow()

	If tObj.BlockedUntil > tNow {
		Set tWait = tObj.BlockedUntil - tNow
		Lock -^WeChatTokenLock(pKey)
		Set pSC = $$$ERROR($$$GeneralError, "WeCom access_token refresh is blocked for another "_tWait_"s after "_tObj.SecretFailures_" consecutive credential failures (last errcode "_tObj.LastErrcode_"). Official warning: repeated secret failures get the source IP banned for one hour, which would affect every application behind this IP. Correct the corpsecret/agentid pair, then call WeChat.Data.AccessToken.Reset().")
		Quit 0
	}

	// 锁内重检：等待期间竞争进程可能已完成。
	Set tToken2 = "", tVersion2 = 0
	Set tToken2 = ..CachedLocked(pKey, .tVersion2)
	If tToken2 '= "" {
		Set pToken = tToken2, pVersion = tVersion2
		Lock -^WeChatTokenLock(pKey)
		Quit 0
	}
	Quit 1
}

/// 已持锁时使用的 Cached()；逻辑完全相同，仅为让调用点的锁规范可读。
ClassMethod CachedLocked(pKey As %String, Output pVersion As %BigInt) As %String
{
	Quit ..Cached(pKey, .pVersion)
}

/// 持久化刚获取的 token 并释放刷新锁。
ClassMethod StoreRefreshed(pKey As %String, pToken As %String, pExpiresIn As %Integer, Output pVersion As %BigInt) As %Status
{
	Set pVersion = 0
	Set tSC = $$$OK
	Try {
		Set tObj = ..Open(pKey)
		Set tNow = ##class(WeChat.Util.Http).EpochNow()
		Set tObj.Token = pToken
		Set tObj.IssuedAt = tNow
		Set tObj.ExpiresAt = tNow + $Select(pExpiresIn > 0:pExpiresIn, 1:7200)
		Set tObj.Version = tObj.Version + 1
		Set tObj.SecretFailures = 0
		Set tObj.BlockedUntil = 0
		Set tObj.LastErrcode = 0
		Set pVersion = tObj.Version
		Set tSC = tObj.%Save()
	} Catch ex {
		Set tSC = ex.AsStatus()
	}
	Lock -^WeChatTokenLock(pKey)
	Quit tSC
}

/// 记录一次失败的 gettoken 并释放刷新锁。凭据类失败会推进熔断计数。
ClassMethod StoreFailure(pKey As %String, pErrcode As %Integer) As %Status
{
	Set tSC = $$$OK
	Try {
		Set tObj = ..Open(pKey)
		Set tNow = ##class(WeChat.Util.Http).EpochNow()
		Set tObj.LastErrcode = pErrcode
		Set tObj.LastErrorAt = tNow
		If ##class(WeChat.Util.Errors).IsCredentialFailure(pErrcode) {
			Set tObj.SecretFailures = tObj.SecretFailures + 1
			If tObj.SecretFailures >= ..#MAXSECRETFAILURES {
				Set tObj.BlockedUntil = tNow + ..#BLOCKSECONDS
			}
		}
		Set tSC = tObj.%Save()
	} Catch ex {
		Set tSC = ex.AsStatus()
	}
	Lock -^WeChatTokenLock(pKey)
	Quit tSC
}

/// 释放刷新锁且不记录任何内容，用于未观察到平台 errcode 的传输错误。
ClassMethod AbortRefresh(pKey As %String)
{
	Lock -^WeChatTokenLock(pKey)
}

/// 平台报告缓存 token 无效（40014 / 42001）后条件性丢弃；版本守卫防止迟到的
/// 调用方丢弃已被其他进程替换的 token。
ClassMethod Invalidate(pKey As %String, pExpectedVersion As %BigInt) As %Status
{
	Lock +^WeChatTokenLock(pKey):..#LOCKTIMEOUT
	If '$Test Quit $$$ERROR($$$GeneralError, "Cannot acquire the token lock to invalidate")
	Set tSC = $$$OK
	Try {
		Set tObj = ..Open(pKey)
		If tObj.Version = pExpectedVersion {
			Set tObj.Token = ""
			Set tObj.ExpiresAt = 0
			Set tSC = tObj.%Save()
		}
	} Catch ex {
		Set tSC = ex.AsStatus()
	}
	Lock -^WeChatTokenLock(pKey)
	Quit tSC
}

/// 记录消息发送调用中观察到的凭据失败，使平台拒绝的是应用而非 gettoken
/// 调用时，熔断器同样触发。
ClassMethod RecordCredentialFailure(pKey As %String, pErrcode As %Integer) As %Status
{
	Lock +^WeChatTokenLock(pKey):..#LOCKTIMEOUT
	If '$Test Quit $$$ERROR($$$GeneralError, "Cannot acquire the token lock to record a failure")
	Set tSC = $$$OK
	Try {
		Set tObj = ..Open(pKey)
		Set tNow = ##class(WeChat.Util.Http).EpochNow()
		Set tObj.LastErrcode = pErrcode
		Set tObj.LastErrorAt = tNow
		If ##class(WeChat.Util.Errors).IsCredentialFailure(pErrcode) {
			Set tObj.SecretFailures = tObj.SecretFailures + 1
			If tObj.SecretFailures >= ..#MAXSECRETFAILURES {
				Set tObj.BlockedUntil = tNow + ..#BLOCKSECONDS
			}
		}
		Set tSC = tObj.%Save()
	} Catch ex {
		Set tSC = ex.AsStatus()
	}
	Lock -^WeChatTokenLock(pKey)
	Quit tSC
}

/// 运维人员修正凭据后清除熔断状态。
ClassMethod Reset(pKey As %String) As %Status
{
	Lock +^WeChatTokenLock(pKey):..#LOCKTIMEOUT
	If '$Test Quit $$$ERROR($$$GeneralError, "Cannot acquire the token lock to reset")
	Set tSC = $$$OK
	Try {
		Set tObj = ..Open(pKey)
		Set tObj.SecretFailures = 0
		Set tObj.BlockedUntil = 0
		Set tObj.Token = ""
		Set tObj.ExpiresAt = 0
		Set tSC = tObj.%Save()
	} Catch ex {
		Set tSC = ex.AsStatus()
	}
	Lock -^WeChatTokenLock(pKey)
	Quit tSC
}

/// 脱敏后的诊断视图。绝不返回 token。
ClassMethod Peek(pKey As %String) As %String
{
	If '..IsPersisted(pKey) Quit "no cache entry"
	Set tObj = ..Open(pKey)
	If '$IsObject(tObj) Quit "no cache entry"
	Set tNow = ##class(WeChat.Util.Http).EpochNow()
	Set tState = "stale"
	If tObj.BlockedUntil > tNow {
		Set tState = "blocked"
	} ElseIf tObj.Token = "" {
		Set tState = "empty"
	} ElseIf (tObj.ExpiresAt - ..#REFRESHWINDOW) > tNow {
		Set tState = "valid"
	}
	Set tTTL = 0
	If tObj.ExpiresAt > tNow Set tTTL = tObj.ExpiresAt - tNow
	Set tBlockedFor = 0
	If tObj.BlockedUntil > tNow Set tBlockedFor = tObj.BlockedUntil - tNow
	Quit "state="_tState_" version="_tObj.Version_" ttl="_tTTL_"s secretFailures="_tObj.SecretFailures_" blockedFor="_tBlockedFor_"s lastErrcode="_tObj.LastErrcode
}

}
