/// 企业微信各渠道共用的出站传输层。业务失败同样返回 HTTP 200，真实结果在
/// 响应体的 errcode 中，消息推送渠道甚至没有文档化的响应体；因此成功与否
/// 首先依据解析后的响应体判定，HTTP 状态码只在没有可用 errcode 时才起作用。
/// 结果分四类：accepted（errcode 0，无无效接收者）、partial（errcode 0，
/// 部分接收者无效或无许可）、rejected（平台拒绝，或发送前本地校验拒绝）、
/// unknown（无法判断平台是否已收到或处理了该请求）。
/// "unknown" 绝不自动重发：请求可能已送达，盲目重试会造成消息重复。只有
/// -1（系统繁忙）会重试且受 MaxAttempts 约束——这是官方文档唯一指示重试的
/// 错误码（"建议重试次数不超过3次"）。40014/42001 刷新 token 一次；45009
/// 需显式开启才重试，官方指引是"仅系统失败需要重试"。
Class WeChat.Adapter.Outbound.Base Extends Ens.OutboundAdapter
{

Parameter SETTINGS = "ApiBaseUrl:Basic,SSLConfig:Basic,Timeout:Basic,MaxAttempts:Basic,RetryBaseSeconds:Basic,RetryOnThrottle:Basic,ThrottleWaitSeconds:Basic,TreatEmptyBodyAsAccepted:Basic";

/// API base URL，例如 https://qyapi.weixin.qq.com。默认值由子类提供。
Property ApiBaseUrl As %String(MAXLEN = 300);

/// HTTPS 调用使用的 TLS 配置名。留空则使用系统默认配置。
Property SSLConfig As %String(MAXLEN = 100);

/// 连接与请求超时时间，单位为秒。
Property Timeout As %Integer [ InitialExpression = 30 ];

/// 单条消息的发送尝试总次数上限（含首次、token 刷新与限流重试）。
/// 官方对 -1 的建议为最多 3 次。
Property MaxAttempts As %Integer [ InitialExpression = 3 ];

/// 指数退避的基础延迟，单位为秒。
Property RetryBaseSeconds As %Numeric [ InitialExpression = 1 ];

/// errcode 45009 的可选重试。默认关闭：官方指引只有系统失败才应重试，
/// 且拦截时间窗与限流时间窗相同。
Property RetryOnThrottle As %Boolean [ InitialExpression = 0 ];

/// 45009 重试前的等待秒数。官方说明分钟级限流在触发一分钟后解除；此值
/// 须按实际适用的时间窗设置，不能一律假定为 60 秒。
Property ThrottleWaitSeconds As %Integer [ InitialExpression = 60 ];

/// 仅消息推送渠道：把"HTTP 2xx 且响应体为空"视为 accepted。
/// 默认关闭，空响应体上报 unknown——这是对未文档化响应的安全解读；但若
/// 平台确实以空响应体作答，每次成功发送都会上报 unknown。请先以真实账号
/// 确认实际响应字节，再据此设定默认值。
Property TreatEmptyBodyAsAccepted As %Boolean [ InitialExpression = 0 ];

// ---------------------------------------------------------------- 渠道钩子

/// 用于响应和校验的渠道名。
Method ChannelName() As %String
{
	Quit ""
}

/// 该渠道的默认 API base URL。
Method DefaultBaseUrl() As %String
{
	Quit ""
}

/// 渠道特有的配置校验，在 OnInit 时执行。
Method ValidateConfig() As %Status
{
	Quit $$$OK
}

/// 单条消息的相对请求路径，例如 /cgi-bin/message/send。
Method RequestPath() As %String
{
	Quit ""
}

/// 为单次尝试做准备（如获取 access_token），在任何数据上线之前。此处返回
/// 错误会中止尝试且不发送任何内容，结果是确定的拒绝而非 unknown。token
/// 获取失败绝不能退化为空 token 发送：既浪费一次调用，又抛出 errcode 41001
/// 掩盖真正的凭证问题。
Method PrepareRequest(pRequest As WeChat.Message.Outbound) As %Status
{
	Quit $$$OK
}

/// 单条消息的查询字符串。必须已完成百分号编码，且绝不能未经脱敏就写入日志，
/// 因为它携带凭证。
Method RequestQuery(pRequest As WeChat.Message.Outbound) As %String
{
	Quit ""
}

/// 构建单条消息的 JSON 请求体。
Method BuildPayload(pRequest As WeChat.Message.Outbound) As %DynamicObject
{
	Quit {}
}

/// 将平台特有的成功字段（msgid、invaliduser 等）读入 pResponse。
Method ParseSuccess(pJSON As %DynamicAbstractObject, pResponse As WeChat.Message.SendResponse)
{
}

/// 对平台 errcode 的渠道特有处理，例如喂给 token 熔断器。在分类之后执行。
Method OnErrcode(pErrcode As %Integer, pRequest As WeChat.Message.Outbound)
{
}

Method OnInit() As %Status
{
	If ..ApiBaseUrl = "" Set ..ApiBaseUrl = ..DefaultBaseUrl()
	If ..MaxAttempts < 1 Set ..MaxAttempts = 1
	Quit ..ValidateConfig()
}

// ----------------------------------------------------------------------- 发送

/// 发送一条消息，结果在 pResponse 中报告：平台接受（accepted/partial）返回
/// $$$OK，rejected 和 unknown 返回错误状态，使 Ensemble 调用方能看到失败并
/// 进行路由；无论返回状态如何，确切结果始终在 pResponse.Result 中。
Method Send(pRequest As WeChat.Message.Outbound, Output pResponse As WeChat.Message.SendResponse) As %Status
{
	Set pResponse = ##class(WeChat.Message.SendResponse).%New()
	Set pResponse.Channel = ..ChannelName()
	Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTUNKNOWN

	Set tStart = $ZTIMESTAMP

	// 先做本地校验：平台对超长消息要么在字符中间截断，要么行为没有文档说明，
	// 因此非法消息绝不能到达平台。
	Set tValidateSC = ##class(WeChat.Util.WeCom).Validate(pRequest)
	If $$$ISERR(tValidateSC) {
		Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTREJECTED
		Set pResponse.ErrorMessage = "Local validation refused the message: " _ $System.Status.GetErrorText(tValidateSC)
		Set pResponse.LatencyMs = ##class(WeChat.Util.Http).ElapsedMs(tStart)
		$$$LOGWARNING("WeCom "_..ChannelName()_" send refused locally: "_$System.Status.GetErrorText(tValidateSC))
		Quit tValidateSC
	}

	Set tAttempt = 0
	Set tDone = 0
	Set tSC = $$$OK
	Set tTokenRetried = 0
	Set tThrottleRetried = 0

	While ('tDone) && (tAttempt < ..MaxAttempts) {
		Set tAttempt = tAttempt + 1
		Set pResponse.Attempts = tAttempt

		Set tOutcome = "", tErrcode = 0, tErrmsg = "", tHttpStatus = 0, tBody = "", tHasCode = 0
		Set tCallSC = ..CallOnce(pRequest, .tHttpStatus, .tBody, .tErrcode, .tErrmsg, .tHasCode, .tOutcome)
		Set pResponse.HttpStatus = tHttpStatus

		// 只有一条 If/ElseIf 链，刻意不用裸 Quit：在 ObjectScript 花括号语法中，
		// If 块内的 Quit 会终止最内层的 DO 循环（这里是 While），导致第一次尝试
		// 后就退出重试循环，Result 停留在初始的 "unknown"。需继续的分支向下落空，
		// 结束的分支设置 tDone。
		If tOutcome = "accepted" {
			Set pResponse.ErrorCodePresent = tHasCode
			Set pResponse.ErrorCode = 0
			Set pResponse.RawErrmsg = tErrmsg
			Do ..ParseSuccess(..ParseBody(tBody), pResponse)
			Set pResponse.Result = $Select(pResponse.HasPartialFailure():##class(WeChat.Util.Errors).#RESULTPARTIAL, 1:##class(WeChat.Util.Errors).#RESULTACCEPTED)
			Set pResponse.Success = 1
			Set tSC = $$$OK
			Set tDone = 1
		} ElseIf tOutcome = "rejected" {
			Set pResponse.ErrorCodePresent = tHasCode
			Set pResponse.ErrorCode = tErrcode
			Set pResponse.RawErrmsg = tErrmsg
			Set pResponse.ErrorMessage = ..RejectionText(tErrcode, tHttpStatus, tBody)
			Do ..OnErrcode(tErrcode, pRequest)
			Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTREJECTED
			Set tSC = $$$ERROR($$$GeneralError, pResponse.ErrorMessage)
			Set tDone = 1
		} ElseIf tOutcome = "unknown" {
			// 绝不自动重发：请求可能已经送达。
			Set pResponse.ErrorCodePresent = 0
			Set pResponse.ErrorMessage = ..UnknownText(tCallSC, tHttpStatus, tBody)
			Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTUNKNOWN
			Set tSC = $$$ERROR($$$GeneralError, pResponse.ErrorMessage)
			$$$LOGWARNING("WeCom "_..ChannelName()_" send outcome UNKNOWN on attempt "_tAttempt_": "_pResponse.ErrorMessage)
			Set tDone = 1
		} ElseIf tOutcome = "token" {
			Set pResponse.TokenRefreshed = 1
			Do ..OnErrcode(tErrcode, pRequest)
			Set tTokenRetried = tTokenRetried + 1
			// 每次发送只做一次 token 刷新，且仍受 MaxAttempts 约束。
			If (tTokenRetried > 1) || (tAttempt >= ..MaxAttempts) {
				Set pResponse.ErrorCodePresent = tHasCode
				Set pResponse.ErrorCode = tErrcode
				Set pResponse.RawErrmsg = tErrmsg
				Set pResponse.ErrorMessage = ..RejectionText(tErrcode, tHttpStatus, tBody) _ " Token refresh did not resolve it."
				Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTREJECTED
				Set tSC = $$$ERROR($$$GeneralError, pResponse.ErrorMessage)
				Set tDone = 1
			} Else {
				Do ..InvalidateTokenForRetry()
			}
		} ElseIf tOutcome = "throttle" {
			Set tThrottleRetried = tThrottleRetried + 1
			If ('..RetryOnThrottle) || (tThrottleRetried > 1) || (tAttempt >= ..MaxAttempts) {
				Set pResponse.ErrorCodePresent = tHasCode
				Set pResponse.ErrorCode = tErrcode
				Set pResponse.RawErrmsg = tErrmsg
				Set pResponse.ErrorMessage = ..RejectionText(tErrcode, tHttpStatus, tBody)
				If '..RetryOnThrottle Set pResponse.ErrorMessage = pResponse.ErrorMessage _ " Throttle retry is disabled (RetryOnThrottle=0)."
				Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTREJECTED
				Set tSC = $$$ERROR($$$GeneralError, pResponse.ErrorMessage)
				Set tDone = 1
			} Else {
				Hang ..ThrottleWaitSeconds
			}
		} ElseIf tOutcome = "retry" {
			// 只有 -1 会走到这里：这是官方文档唯一指示要重试的错误码。
			If tAttempt >= ..MaxAttempts {
				Set pResponse.ErrorCodePresent = tHasCode
				Set pResponse.ErrorCode = tErrcode
				Set pResponse.RawErrmsg = tErrmsg
				Set pResponse.ErrorMessage = ..RejectionText(tErrcode, tHttpStatus, tBody) _ " Exhausted "_tAttempt_" attempts."
				Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTREJECTED
				Set tSC = $$$ERROR($$$GeneralError, pResponse.ErrorMessage)
				Set tDone = 1
			} Else {
				Hang (..RetryBaseSeconds * tAttempt)
			}
		} ElseIf tOutcome = "aborted" {
			// 准备阶段失败，未发送任何字节：确定的拒绝而非 unknown，可安全补偿。
			Set pResponse.ErrorCodePresent = 0
			Set pResponse.ErrorMessage = "The request was NOT sent: " _ $System.Status.GetErrorText(tCallSC)
			Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTREJECTED
			Set tSC = $$$ERROR($$$GeneralError, pResponse.ErrorMessage)
			$$$LOGERROR("WeCom "_..ChannelName()_" send aborted before transmission: "_$System.Status.GetErrorText(tCallSC))
			Set tDone = 1
		} Else {
			// 不可达，除非子类返回了无法识别的结果标签。
			Set pResponse.ErrorMessage = "Internal error: unclassified send outcome '"_tOutcome_"'"
			Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTUNKNOWN
			Set tSC = $$$ERROR($$$GeneralError, pResponse.ErrorMessage)
			Set tDone = 1
		}
	}

	Set pResponse.LatencyMs = ##class(WeChat.Util.Http).ElapsedMs(tStart)
	Do ..OnResponse(pResponse, pRequest)
	Quit tSC
}

/// 每次 Send 在结果确定后调用一次的钩子。应用渠道会重写它以记录部分送达。
Method OnResponse(pResponse As WeChat.Message.SendResponse, pRequest As WeChat.Message.Outbound)
{
}

// ------------------------------------------------------------------- 传输

/// 执行一次 HTTP 尝试并分类，pOutcome 为 accepted、rejected、unknown、
/// token、throttle、retry 之一。分类首先依据 errcode，只有在没有可用
/// errcode 时才参考 HTTP 状态码。
Method CallOnce(pRequest As WeChat.Message.Outbound, Output pHttpStatus As %Integer, Output pBody As %String, Output pErrcode As %Integer, Output pErrmsg As %String, Output pHasErrcode As %Boolean, Output pOutcome As %String) As %Status
{
	Set pHttpStatus = 0, pBody = "", pErrcode = 0, pErrmsg = "", pHasErrcode = 0, pOutcome = "unknown"
	Set tSC = $$$OK

	Set tPrepSC = ..PrepareRequest(pRequest)
	If $$$ISERR(tPrepSC) {
		// 未发送任何内容，因此可以确定没有送达。
		Set pOutcome = "aborted"
		Quit tPrepSC
	}

	Set tQuery = ..RequestQuery(pRequest)
	Set tPath = ..RequestPath()
	If tQuery '= "" Set tPath = tPath _ "?" _ tQuery

	Set tHttp = ##class(%Net.HttpRequest).%New()
	Set tHttp.Timeout = ..Timeout
	Set tHttp.OpenTimeout = ..Timeout
	If ..SSLConfig '= "" Set tHttp.SSLConfiguration = ..SSLConfig

	// 顺序很重要：必须先创建实体流再设 ContentType 和 ContentCharset，
	// 否则非 ASCII 内容会被破坏。
	Set tHttp.EntityBody = ##class(%Stream.GlobalCharacter).%New()
	Set tHttp.ContentType = "application/json"
	Set tHttp.ContentCharset = "utf-8"

	Set tPayload = ..BuildPayload(pRequest)
	Do tHttp.EntityBody.Write(tPayload.%ToJSON())

	Set tParts = ""
	Do ##class(%Net.URLParser).Parse(..ApiBaseUrl _ tPath, .tParts)
	Set tHttp.Server = $Get(tParts("host"))
	Set tHttp.Https = ($ZConvert($Get(tParts("scheme")), "L") = "https")
	Set tHttp.Port = $Select($Get(tParts("port")) '= "": +$Get(tParts("port")), tHttp.Https:443, 1:80)
	Set tTarget = $Get(tParts("path"))
	If tTarget = "" Set tTarget = "/"
	If $Get(tParts("query")) '= "" Set tTarget = tTarget _ "?" _ $Get(tParts("query"))

	Set tPostSC = $$$OK
	Try {
		Set tPostSC = tHttp.Post(tTarget)
	} Catch ex {
		Set tPostSC = ex.AsStatus()
	}

	If $$$ISERR(tPostSC) {
		// 完全没有响应：请求可能到达平台也可能没有，是 unknown，不能自动重发。
		Set pOutcome = "unknown"
		Quit tPostSC
	}

	Set pHttpStatus = tHttp.HttpResponse.StatusCode
	Set pBody = ..ReadAll(tHttp.HttpResponse.Data)

	Quit ..Classify(pHttpStatus, pBody, .pErrcode, .pErrmsg, .pHasErrcode, .pOutcome)
}

/// 根据 HTTP 状态码和解析后的响应体判定结果。
Method Classify(pHttpStatus As %Integer, pBody As %String, Output pErrcode As %Integer, Output pErrmsg As %String, Output pHasErrcode As %Boolean, Output pOutcome As %String) As %Status
{
	Set pErrcode = 0, pErrmsg = "", pHasErrcode = 0, pOutcome = "unknown"

	Set tJSON = ..ParseBody(pBody)
	Set tHasErrcode = ##class(WeChat.Util.Errors).HasErrcode(tJSON)
	Set pHasErrcode = tHasErrcode

	If tHasErrcode {
		Set pErrcode = ##class(WeChat.Util.Errors).ReadErrcode(tJSON)
		Set pErrmsg = ##class(WeChat.Util.Errors).ReadString(tJSON, "errmsg")
		If pErrcode = 0 {
			Set pOutcome = "accepted"
			Quit $$$OK
		}
		Set tDisposition = ##class(WeChat.Util.Errors).Disposition(pErrcode)
		Set pOutcome = "rejected"
		If tDisposition = ##class(WeChat.Util.Errors).#DISPOSITIONRETRY {
			Set pOutcome = "retry"
		} ElseIf tDisposition = ##class(WeChat.Util.Errors).#DISPOSITIONTOKEN {
			Set pOutcome = "token"
		} ElseIf tDisposition = ##class(WeChat.Util.Errors).#DISPOSITIONTHROTTLE {
			Set pOutcome = "throttle"
		}
		Quit $$$OK
	}

	// 没有可用的 errcode：消息推送渠道无文档化响应体，空响应体本身就存在歧义；
	// 应用渠道有文档化响应体，那里缺少 errcode 属于异常。
	If (pHttpStatus >= 200) && (pHttpStatus < 300) {
		If $ZStrip(pBody, "<>W") = "" {
			If (..ChannelName() = "wecomrobot") && ..TreatEmptyBodyAsAccepted {
				Set pOutcome = "accepted"
			} Else {
				Set pOutcome = "unknown"
			}
			Quit $$$OK
		}
		// 非空但不是可用的 errcode：无法判断请求是否已被处理。
		Set pOutcome = "unknown"
		Quit $$$OK
	}

	If (pHttpStatus >= 500) {
		// 平台或中间环节可能已经处理了该请求。
		Set pOutcome = "unknown"
		Quit $$$OK
	}

	// 4xx 表示某个环节在请求被处理之前已明确拒绝它。
	Set pOutcome = "rejected"
	Quit $$$OK
}

/// 将响应体解析为 %DynamicObject，无法使用时返回 ""。
/// %FromJSON 返回对象本身，不是 byref 调用，也不返回状态。
Method ParseBody(pBody As %String) As %DynamicAbstractObject
{
	Set tOut = ""
	If $ZStrip(pBody, "<>W") = "" Quit tOut
	Try {
		Set tJSON = {}.%FromJSON(pBody)
		If $IsObject(tJSON) Set tOut = tJSON
	} Catch ex {
		Set tOut = ""
	}
	Quit tOut
}

/// 读取响应流直到结束。
Method ReadAll(pStream As %Stream.Object) As %String
{
	Set tOut = ""
	If '$IsObject(pStream) Quit tOut
	Try {
		While 'pStream.AtEnd {
			Set tChunk = pStream.Read(32000)
			If tChunk = "" Quit
			Set tOut = tOut _ tChunk
		}
	} Catch ex {
	}
	Quit tOut
}

// ------------------------------------------------------------- 提示文本

/// 发送被拒绝时面向操作员的提示文本。
Method RejectionText(pErrcode As %Integer, pHttpStatus As %Integer, pBody As %String) As %String
{
	Set tDesc = ##class(WeChat.Util.Errors).Describe(pErrcode)
	If tDesc '= "" {
		Quit "WeCom "_..ChannelName()_" refused the message (errcode "_pErrcode_"): "_tDesc
	}
	If pHttpStatus && ((pHttpStatus < 200) || (pHttpStatus >= 300)) {
		Quit "WeCom "_..ChannelName()_" refused the message with HTTP "_pHttpStatus_" ("_##class(WeChat.Util.Http).Reason(pHttpStatus)_") and no platform errcode"
	}
	Quit "WeCom "_..ChannelName()_" refused the message with unrecognised errcode "_pErrcode_"; check the official errcode page"
}

/// 面向操作员的结果不确定提示文本。刻意不回显响应体，因为它可能包含消息内容。
Method UnknownText(pCallSC As %Status, pHttpStatus As %Integer, pBody As %String) As %String
{
	Set tReason = $Select($$$ISERR(pCallSC):"no usable HTTP response ("_$System.Status.GetErrorText(pCallSC)_")", pHttpStatus >= 500:"HTTP "_pHttpStatus_" from the platform or an intermediary", $ZStrip(pBody, "<>W") = "":"HTTP "_pHttpStatus_" with an empty body", 1:"HTTP "_pHttpStatus_" with a body that carried no usable errcode")
	Quit "WeCom "_..ChannelName()_" send outcome is UNKNOWN: "_tReason_". The message may already have been delivered, so it was NOT resent automatically. Confirm before compensating; EnableDuplicateCheck reduces (but does not eliminate) the risk of a duplicate."
}

// ------------------------------------------------------------- token 支持

/// 在 token 处置类重试前丢弃缓存的 token。由应用渠道 adapter 重写，它是唯一
/// 使用 access_token 的渠道。
Method InvalidateTokenForRetry()
{
}

}
