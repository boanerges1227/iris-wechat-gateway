/// WeCom errcode 分类。
///
/// 「开发者的程序应该根据 errcode 来判断出错的情况，而不应该依赖 errmsg 来匹配，
/// 因为 errmsg 可能会调整」（全局 errcode 页面）。本类不匹配 errmsg 文本，
/// 平台消息仅原样传递，用于诊断。
///
/// 官方文档没有「可重试 errcode」清单，唯一指引是 -1「服务器暂不可用，建议稍候
/// 重试。建议重试次数不超过3次」和 45009「接口实现时，仅系统失败需要重试。其余
/// 错误码，应该排查下调用失败原因」；下面的分类是从这两段表述推导出的工程决策，
/// 未知编码默认不重试。编码逐一显式枚举，禁止范围或前缀启发式，因为消息推送的编码为负数（-1 和 -93xxx 系列）。
Class WeChat.Util.Errors
{

/// SendResponse.Result 使用的结果类别。
Parameter RESULTACCEPTED = "accepted";
Parameter RESULTPARTIAL = "partial";
Parameter RESULTREJECTED = "rejected";
Parameter RESULTUNKNOWN = "unknown";

/// Disposition() 返回的重试处置。
Parameter DISPOSITIONRETRY = "retry";
Parameter DISPOSITIONTOKEN = "token";
Parameter DISPOSITIONTHROTTLE = "throttle";
Parameter DISPOSITIONFATAL = "fatal";

/// 对单个平台 errcode 进行分类。
///
/// retry    - 平台明确要求重试的系统失败（仅 -1）
/// token    - access_token 无效或过期；刷新一次后重试
/// throttle - 频率拦截；默认不重试
/// fatal    - 其余所有有明确含义的错误
ClassMethod Disposition(pErrcode As %Integer) As %String
{
	// 系统失败。官方：可重试，最多 3 次。
	If pErrcode = -1 Quit ..#DISPOSITIONRETRY

	// access_token 无效 / 过期。官方：「需要重新获取一次」。
	If pErrcode = 40014 Quit ..#DISPOSITIONTOKEN
	If pErrcode = 42001 Quit ..#DISPOSITIONTOKEN

	// 频率拦截。官方：拦截持续时间与限频窗口相同（分钟级限频一分钟后解除），
	// 且「仅系统失败需要重试」，因此是否重试仅限显式选择加入。
	If pErrcode = 45009 Quit ..#DISPOSITIONTHROTTLE

	// 下面枚举的其他编码全部为 fatal；任何未枚举的编码同样按 fatal 处理
	// （官方倾向：排查原因，不要重试）。
	Quit ..#DISPOSITIONFATAL
}

/// 当该编码表示平台要求我们重试的系统失败时为真。
ClassMethod IsRetryable(pErrcode As %Integer) As %Boolean
{
	Quit pErrcode = -1
}

/// 当重试前应重新获取 access_token 时为真。
ClassMethod NeedsTokenRefresh(pErrcode As %Integer) As %Boolean
{
	Quit (pErrcode = 40014) || (pErrcode = 42001)
}

/// 频率拦截（45009）时为真。是否重试为显式选择加入，因为官方
/// 拦截窗口等于限频窗口。
ClassMethod IsThrottled(pErrcode As %Integer) As %Boolean
{
	Quit pErrcode = 45009
}

/// 凭据类失败时为真。这类编码会触发 WeChat.Data.AccessToken 中的熔断器：
/// 官方 45009 排障文案指出 secret 反复出错会封禁源 IP 一小时，
/// 拖垮共享同一条出口 IP 的所有其他应用。
ClassMethod IsCredentialFailure(pErrcode As %Integer) As %Boolean
{
	Quit (pErrcode = 40001) || (pErrcode = 40091) || (pErrcode = 45031)
}

/// 当 errcode 属于本网关有明确解释的编码时为真；未知编码报告为未识别，
/// 以便运维人员去查官方 errcode 页面。
ClassMethod IsKnown(pErrcode As %Integer) As %Boolean
{
	Quit ..Describe(pErrcode) '= ""
}

/// 面向运维人员的平台 errcode 解释。使用我们自己的措辞，绝不匹配
/// errmsg。空字符串表示「此处未枚举」。
ClassMethod Describe(pErrcode As %Integer) As %String
{
	Quit $Case(pErrcode,
		// --- 成功 / 系统 ------------------------------------------------------
		0:"ok",
		-1:"System busy. Official guidance: retry later, at most 3 attempts.",
		6000:"Data version conflict; another caller is modifying the same data.",

		// --- access_token ----------------------------------------------------
		40001:"Invalid secret, corpid/secret mismatch, or the application is disabled. NOT retried: repeated secret failures get the source IP banned for one hour.",
		40014:"Invalid access_token (expired, malformed, or issued for a different application type). Refresh once and retry.",
		40091:"Invalid secret; it may belong to a different enterprise.",
		41001:"Missing access_token. It must be appended to the URL, never placed in the request body.",
		42001:"access_token expired. Refresh once and retry.",
		45031:"Enterprise corpsecret is not secure enough and must be reset.",

		// --- 频率 / 并发 ------------------------------------------------------
		45009:"API call limit exceeded. Official guidance: only system failures should be retried. Interception lasts as long as the limit window (minute-level limits clear after one minute).",
		45033:"Concurrent calls to the same API exceeded the limit. Lower the concurrency; do not retry.",

		// --- IP / 权限 --------------------------------------------------------
		60020:"Unsafe access IP. For a self-built application the egress IP must be listed under the application's 企业可信IP. Note: a newly added trusted IP takes one minute to take effect.",
		48002:"API not permitted for this application. A contacts-sync assistant token can only sync contacts and CANNOT send messages; use a self-built application secret.",
		301002:"No permission to operate the specified application: the access_token was issued for a different agentid. Confirm corpsecret and agentid belong to the same self-built application.",
		50003:"Application is disabled; re-enable it under 管理端 - 应用管理.",
		60031:"This application is forbidden from calling the API.",

		// --- agentid -----------------------------------------------------------
		40056:"Invalid agentid. It must be an integer and the application must exist in the admin console.",
		41011:"Missing agentid parameter.",

		// --- 参数 -------------------------------------------------------------
		40033:"Illegal request character. Official text: content cannot contain \uxxxx format characters.",
		40035:"Invalid parameter (recipient list shape or size).",
		40058:"Invalid parameter or malformed JSON. Official note: a non-conforming body yields errmsg containing 'Warning: wrong json format.'",
		40063:"Required parameter is empty. Check the HTTP method and that the body is JSON, not form data.",
		44004:"Text message content is empty; it is required and cannot be blank.",
		45002:"Message content exceeds the size limit (text 2048 bytes; mpnews 666 KB).",
		81012:"Missing visible range: touser, toparty and totag cannot all be empty.",
		82001:"All of touser / toparty / totag were empty.",
		82002:"Invalid partyid list length; a single send cannot exceed 100 departments.",
		82003:"Invalid tagid list length; a single send cannot exceed 100 tags.",

		// --- 收件人 -----------------------------------------------------------
		81013:"Every userid, partyid and tagid was invalid or unauthorized. Either the members/departments/tags were deleted, or they are outside the application's visible range.",
		60111:"Userid does not exist: not a legal userid, the member left or was deleted, or the member is outside the application's visible range.",
		40003:"Invalid userid. Legal userids are 1-64 characters of letters, digits, hyphen, underscore and dot.",
		40031:"Invalid userid list; check spelling and that every userid is inside the application's visible range.",
		60011:"No permission for the specified member/department/tag; it is outside the application's visible range.",
		60021:"Userid is not inside the application's visible range.",

		// --- 内容 -------------------------------------------------------------
		40201:"Content was blocked by the anti-spam filter.",
		40204:"Blocked by WeChat anti-spam.",
		82004:"Illegal message content; it may contain something that crashes the client.",

		// --- 媒体文件（属 V2，此处先枚举以便 V1 失败时可读） ------------------
		40007:"Invalid media_id: wrong source, expired (temporary media lasts 3 days), or the type does not match the message type.",
		40145:"media_id has expired.",
		41006:"Missing media_id parameter.",
		45001:"Multimedia file exceeds the size limit.",
		45008:"A news message cannot contain more than 8 articles.",

		// --- 消息推送（webhook）专属编码，全部为负数 ---------------------------
		-93000:"Message push webhook URL is invalid, or the robot has been removed from the group chat.",
		-93001:"This group chat does not allow message push.",
		-93004:"This message push has been disabled.",
		-93006:"Invalid group chat id.",
		-93008:"Not a member of the group chat.",
		-93017:"Message push request content cannot be empty.",
		-93018:"Image exceeds the size limit.",
		-93019:"Invalid robot id (webhook key).",
		-93050:"Invalid response_type field.",

		:"")
}

/// 处置结果的短标签，用于日志行和 SendResponse。
ClassMethod DispositionLabel(pDisposition As %String) As %String
{
	If pDisposition = ..#DISPOSITIONRETRY Quit "retryable system failure"
	If pDisposition = ..#DISPOSITIONTOKEN Quit "access_token needs refresh"
	If pDisposition = ..#DISPOSITIONTHROTTLE Quit "frequency intercepted"
	If pDisposition = ..#DISPOSITIONFATAL Quit "permanent rejection"
	Quit "unknown"
}

/// 当 JSON 响应体带有可用的 errcode 时为真。消息推送渠道没有官方记载的响应体，
/// 因此必须区分「无 errcode」与「errcode 为零」。
ClassMethod HasErrcode(pJSON As %DynamicAbstractObject) As %Boolean
{
	Set tOut = 0
	If '$IsObject(pJSON) Quit tOut
	Try {
		If pJSON.%IsDefined("errcode") {
			Set tValue = pJSON.%Get("errcode")
			If '$IsObject(tValue) && (tValue '= "") Set tOut = 1
		}
	} Catch ex {
		Set tOut = 0
	}
	Quit tOut
}

/// 以带符号整数读取 errcode。消息推送编码为负数，因此该值
/// 不得经由无符号路径强制转换。
ClassMethod ReadErrcode(pJSON As %DynamicAbstractObject) As %Integer
{
	Set tOut = 0
	Try {
		Set tValue = pJSON.%Get("errcode")
		If '$IsObject(tValue) && (tValue '= "") {
			If (tValue?1N.E) || (tValue?1"-".N.E) Set tOut = +tValue
		}
	} Catch ex {
		Set tOut = 0
	}
	Quit tOut
}

/// 防御式读取字符串字段；字段缺失或不是字符串时返回 ""。
ClassMethod ReadString(pJSON As %DynamicAbstractObject, pField As %String) As %String
{
	Set tOut = ""
	Try {
		If $IsObject(pJSON) && pJSON.%IsDefined(pField) {
			Set tValue = pJSON.%Get(pField)
			If '$IsObject(tValue) Set tOut = tValue
		}
	} Catch ex {
		Set tOut = ""
	}
	Quit tOut
}

}
