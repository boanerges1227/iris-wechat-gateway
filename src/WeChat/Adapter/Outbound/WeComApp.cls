/// 企业微信应用消息通道的出站 adapter。
/// GET  https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid={}&corpsecret={}
/// POST https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token={}
/// 本类设计由三条官方约束驱动：“access_token需要拼接在URL中，不能放在请求包体中”
/// （errcode 41001，至多 512 字节）；“每个应用的access_token是彼此独立的，所以进行
/// 缓存时需要区分应用来进行存储”（缓存 key 含 corpid、agentid 与 secret 指纹）；
/// “如果应用的secret错误多次，会导致同一个IP被禁用一小时”（凭据类失败走熔断，不重试）。
/// 另有“每应用对同一个成员不可超过30次/分钟，1000次/小时，超过部分会被丢弃不下发”：
/// 被接受不等于已送达；V1 有意未实现客户端限流，要求调用方自行节流。
Class WeChat.Adapter.Outbound.WeComApp Extends WeChat.Adapter.Outbound.Base
{

Parameter SETTINGS = "CorpId:Basic,CorpSecret:Basic,SecretCredential:Basic,AgentId:Basic,ApiBaseUrl:Basic,SSLConfig:Basic,Timeout:Basic,MaxAttempts:Basic,RetryBaseSeconds:Basic,RetryOnThrottle:Basic,ThrottleWaitSeconds:Basic,TreatEmptyBodyAsAccepted:Basic";

/// 企业 ID（corpid）。
Property CorpId As %String(MAXLEN = 100);

/// 明文应用 secret，优先使用 SecretCredential。必须与 AgentId 属于同一个自建
/// 应用；通讯录同步助手的 secret 完全无法发送消息（errcode 48002）。
Property CorpSecret As %String(MAXLEN = 300);

/// 互操作凭据 ID，Password 存放 corpsecret；若 UserName 已设置，兼作 corpid。
Property SecretCredential As %String(MAXLEN = 100);

/// 应用 ID，取自管理后台的整数。
Property AgentId As %Integer;

/// 缓存的 token 及其版本，用于 40014/42001 时的条件失效。
Property CurrentToken As %String(MAXLEN = 1024) [ Private ];

Property CurrentTokenVersion As %BigInt [ Private, InitialExpression = 0 ];

Property CurrentCacheKey As %String(MAXLEN = 400) [ Private ];

/// 由 PrepareRequest 为当前发送尝试解析出的 token。
Property PendingToken As %String(MAXLEN = 1024) [ Private ];

Method ChannelName() As %String
{
	Quit "wecomapp"
}

Method DefaultBaseUrl() As %String
{
	Quit "https://qyapi.weixin.qq.com"
}

Method ValidateConfig() As %Status
{
	If ..ResolveCorpId() = "" {
		Quit $$$ERROR($$$GeneralError, "The application message adapter requires CorpId (or a SecretCredential whose UserName holds it)")
	}
	If ..ResolveSecret() = "" {
		Quit $$$ERROR($$$GeneralError, "The application message adapter requires CorpSecret or SecretCredential. Use the secret of a SELF-BUILT application; a contacts-sync assistant secret cannot send messages (errcode 48002).")
	}
	If (..AgentId = "") || (..AgentId <= 0) {
		Quit $$$ERROR($$$GeneralError, "The application message adapter requires a positive integer AgentId, from the same self-built application as the secret")
	}
	Quit $$$OK
}

Method RequestPath() As %String
{
	Quit "/cgi-bin/message/send"
}

/// 获取本次尝试所需的 token；失败在发出任何字节之前中止，使调用方看到真实的
/// 凭据错误，而非未认证请求产生的误导性 errcode 41001。
Method PrepareRequest(pRequest As WeChat.Message.Outbound) As %Status
{
	Set tToken = ""
	Set tSC = ..AcquireToken(.tToken)
	If $$$ISERR(tSC) Quit tSC
	Set ..PendingToken = tToken
	Quit $$$OK
}

/// token 只拼接在 URL 中，绝不放入请求包体（errcode 41001）。该值属于凭据，
/// 除经 RedactUrl() 处理外绝不可写入日志。
Method RequestQuery(pRequest As WeChat.Message.Outbound) As %String
{
	Quit "access_token=" _ ##class(WeChat.Util.Http).UrlEncode(..PendingToken)
}

Method BuildPayload(pRequest As WeChat.Message.Outbound) As %DynamicObject
{
	Quit ##class(WeChat.Util.WeCom).BuildAppPayload(pRequest)
}

/// 成功字段。平台返回的 userid 会被转为小写，与请求比较必须忽略大小写
/// （参见 WeChat.Util.WeCom.InIdList）。
Method ParseSuccess(pJSON As %DynamicAbstractObject, pResponse As WeChat.Message.SendResponse)
{
	If '$IsObject(pJSON) Quit
	Set pResponse.MessageId = ##class(WeChat.Util.Errors).ReadString(pJSON, "msgid")
	Set pResponse.ResponseCode = ##class(WeChat.Util.Errors).ReadString(pJSON, "response_code")
	Set pResponse.InvalidUser = ##class(WeChat.Util.Errors).ReadString(pJSON, "invaliduser")
	Set pResponse.InvalidParty = ##class(WeChat.Util.Errors).ReadString(pJSON, "invalidparty")
	Set pResponse.InvalidTag = ##class(WeChat.Util.Errors).ReadString(pJSON, "invalidtag")
	// unlicenseduser 不同于 invaliduser：接收人存在且在可见范围内，只是没有基础接口 licence。
	Set pResponse.UnlicensedUser = ##class(WeChat.Util.Errors).ReadString(pJSON, "unlicenseduser")
}

/// 凭据类失败记入 token 熔断器；平台接受了调用但丢弃接收人时记录警告。
Method OnErrcode(pErrcode As %Integer, pRequest As WeChat.Message.Outbound)
{
	If ##class(WeChat.Util.Errors).IsCredentialFailure(pErrcode) && (..CurrentCacheKey '= "") {
		Do ##class(WeChat.Data.AccessToken).RecordCredentialFailure(..CurrentCacheKey, pErrcode)
		$$$LOGERROR("WeCom credential failure (errcode "_pErrcode_"). Repeated secret failures get the source IP banned for one hour, affecting every application behind this IP. The token cache circuit breaker will stop refreshing after "_##class(WeChat.Data.AccessToken).#MAXSECRETFAILURES_" consecutive failures.")
	}
	If pErrcode = 301002 {
		$$$LOGERROR("WeCom errcode 301002: the access_token was issued for a different application than AgentId "_..AgentId_". Confirm CorpSecret and AgentId belong to the same self-built application.")
	}
	If pErrcode = 60020 {
		$$$LOGERROR("WeCom errcode 60020: this egress IP is not in the application's 企业可信IP list. Note that a newly added trusted IP takes one minute to take effect.")
	}
}

/// 记录部分送达，使被静默丢弃的接收人在生产日志中可见。挂在 Base.OnResponse
/// 而非覆写 Send()，因为经 ##super() 转发 Output 参数较脆弱。
Method OnResponse(pResponse As WeChat.Message.SendResponse, pRequest As WeChat.Message.Outbound)
{
	If '$IsObject(pResponse) Quit
	If pResponse.Result '= ##class(WeChat.Util.Errors).#RESULTPARTIAL Quit
	Set tDetail = ""
	If pResponse.InvalidUser '= "" Set tDetail = tDetail _ " invaliduser="_pResponse.InvalidUser
	If pResponse.InvalidParty '= "" Set tDetail = tDetail _ " invalidparty="_pResponse.InvalidParty
	If pResponse.InvalidTag '= "" Set tDetail = tDetail _ " invalidtag="_pResponse.InvalidTag
	If pResponse.UnlicensedUser '= "" Set tDetail = tDetail _ " unlicenseduser="_pResponse.UnlicensedUser_" (in range but no basic interface licence)"
	$$$LOGWARNING("WeCom application message accepted with partial delivery:"_tDetail)
}

/// 40014/42001 重试前有条件地丢弃缓存 token；版本守卫防止本调用方丢弃已被
/// 其他进程替换的 token。
Method InvalidateTokenForRetry()
{
	If ..CurrentCacheKey = "" Quit
	Do ##class(WeChat.Data.AccessToken).Invalidate(..CurrentCacheKey, ..CurrentTokenVersion)
	Set ..CurrentToken = ""
	Set ..PendingToken = ""
	Set ..CurrentTokenVersion = 0
}

/// 返回可用的 access_token，必要时以单飞（single-flight）方式刷新。
Method AcquireToken(Output pToken As %String) As %Status
{
	Set pToken = ""
	Set tKey = ..TokenCacheKey()
	Set ..CurrentCacheKey = tKey

	Set tVersion = 0
	Set tToken = ##class(WeChat.Data.AccessToken).Cached(tKey, .tVersion)
	If tToken '= "" {
		Set ..CurrentToken = tToken, ..CurrentTokenVersion = tVersion
		Set pToken = tToken
		Quit $$$OK
	}

	Set tOwned = 0, tSC = $$$OK
	Set tOwned = ##class(WeChat.Data.AccessToken).TryBeginRefresh(tKey, .tToken, .tVersion, .tSC)
	If tOwned = 0 {
		If tToken '= "" {
			Set ..CurrentToken = tToken, ..CurrentTokenVersion = tVersion
			Set pToken = tToken
			Quit $$$OK
		}
		Quit tSC
	}

	// 本方持有刷新权；Store*/Abort 中必须且只能执行一个。
	Set tNewToken = "", tExpiresIn = 0, tErrcode = 0, tErrmsg = "", tFetchSC = $$$OK
	Set tFetchSC = ..FetchToken(.tNewToken, .tExpiresIn, .tErrcode, .tErrmsg)
	If $$$ISERR(tFetchSC) {
		Do ##class(WeChat.Data.AccessToken).AbortRefresh(tKey)
		Quit tFetchSC
	}
	If (tErrcode '= 0) || (tNewToken = "") {
		Set tStoreSC = ##class(WeChat.Data.AccessToken).StoreFailure(tKey, tErrcode)
		Set tText = ##class(WeChat.Util.Errors).Describe(tErrcode)
		Quit $$$ADDSC(tStoreSC, $$$ERROR($$$GeneralError, "WeCom gettoken failed with errcode "_tErrcode_": "_tText_" "_tErrmsg))
	}

	Set tVersion = 0
	Set tStoreSC2 = ##class(WeChat.Data.AccessToken).StoreRefreshed(tKey, tNewToken, tExpiresIn, .tVersion)
	If $$$ISERR(tStoreSC2) Quit tStoreSC2
	Set ..CurrentToken = tNewToken, ..CurrentTokenVersion = tVersion
	Set pToken = tNewToken
	Quit $$$OK
}

/// 缓存 key。secret 仅以指纹表示，绝不以明文存储。
Method TokenCacheKey() As %String
{
	Quit ##class(WeChat.Data.AccessToken).KeyFor(..ChannelName(), ..ResolveCorpId(), ..AgentId, ..SecretCredential, ##class(WeChat.Util.Credentials).Fingerprint(..ResolveSecret()), ..ApiBaseUrl)
}

/// 执行 gettoken 的 HTTP 调用。
Method FetchToken(Output pToken As %String, Output pExpiresIn As %Integer, Output pErrcode As %Integer, Output pErrmsg As %String) As %Status
{
	Set pToken = "", pExpiresIn = 0, pErrcode = 0, pErrmsg = ""

	Set tQuery = "corpid=" _ ##class(WeChat.Util.Http).UrlEncode(..ResolveCorpId()) _ "&corpsecret=" _ ##class(WeChat.Util.Http).UrlEncode(..ResolveSecret())
	Set tPath = "/cgi-bin/gettoken?" _ tQuery

	Set tHttp = ##class(%Net.HttpRequest).%New()
	Set tHttp.Timeout = ..Timeout
	Set tHttp.OpenTimeout = ..Timeout
	If ..SSLConfig '= "" Set tHttp.SSLConfiguration = ..SSLConfig

	Set tParts = ""
	Do ##class(%Net.URLParser).Parse(..ApiBaseUrl _ tPath, .tParts)
	Set tHttp.Server = $Get(tParts("host"))
	Set tHttp.Https = ($ZConvert($Get(tParts("scheme")), "L") = "https")
	Set tHttp.Port = $Select($Get(tParts("port")) '= "": +$Get(tParts("port")), tHttp.Https:443, 1:80)
	Set tTarget = $Get(tParts("path"))
	If tTarget = "" Set tTarget = "/"
	If $Get(tParts("query")) '= "" Set tTarget = tTarget _ "?" _ $Get(tParts("query"))

	Set tSC = $$$OK
	Try {
		Set tSC = tHttp.Get(tTarget)
	} Catch ex {
		Set tSC = ex.AsStatus()
	}
	If $$$ISERR(tSC) {
		// 绝不回显 URL：其中携带 corpsecret。
		Quit $$$ERROR($$$GeneralError, "WeCom gettoken transport failure: "_$System.Status.GetErrorText(tSC))
	}

	Set tStatus = tHttp.HttpResponse.StatusCode
	Set tBody = ..ReadAll(tHttp.HttpResponse.Data)
	Set tJSON = ..ParseBody(tBody)

	If '##class(WeChat.Util.Errors).HasErrcode(tJSON) {
		Quit $$$ERROR($$$GeneralError, "WeCom gettoken returned HTTP "_tStatus_" with no usable errcode; cannot determine whether a token was issued")
	}
	Set pErrcode = ##class(WeChat.Util.Errors).ReadErrcode(tJSON)
	Set pErrmsg = ##class(WeChat.Util.Errors).ReadString(tJSON, "errmsg")
	If pErrcode '= 0 Quit $$$OK

	Set pToken = ##class(WeChat.Util.Errors).ReadString(tJSON, "access_token")
	Set tExpires = ##class(WeChat.Util.Errors).ReadString(tJSON, "expires_in")
	Set pExpiresIn = $Select(tExpires?.N:+tExpires, 1:0)
	// 官方最大值为 512 字节；异常超长直接拒绝，不缓存一个根本发不出去的内容。
	If (pToken '= "") && ($Length(pToken) > 1024) {
		Quit $$$ERROR($$$GeneralError, "WeCom gettoken returned an access_token longer than the documented 512-byte maximum")
	}
	Quit $$$OK
}

/// corpid 取自显式配置，否则取自凭据的 UserName。
Method ResolveCorpId() As %String
{
	If ..CorpId '= "" Quit ..CorpId
	Quit ##class(WeChat.Util.Credentials).GetUser(..SecretCredential, "")
}

/// 提供了凭据 ID 时 corpsecret 取自凭据，否则取明文值。
Method ResolveSecret() As %String
{
	Quit ##class(WeChat.Util.Credentials).Get(..SecretCredential, ..CorpSecret)
}

}
