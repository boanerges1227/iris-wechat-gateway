/// 一次出站发送尝试序列的结果。区分四态，因为平台受理不等于最终送达，
/// 响应丢失也不等于被拒绝：accepted（errcode 为 0 且接收者全部有效）、
/// partial（errcode 为 0，但部分接收者无效或未取得许可）、rejected（被
/// 平台或本地校验拒绝）、unknown（无法确定平台是否已接收或已处理）。
/// "unknown" 刻意不重试：请求可能已送达，自动重发会造成重复，是否补偿
/// 由调用方决定，可酌情借助 EnableDuplicateCheck。
/// ErrorCode 保留符号：消息推送错误码是负数（-1 与 -93xxx），丢符号会误判。
/// 不携带原始响应体，诊断仅限脱敏的平台状态元数据；平台 errmsg 透传但绝不用于匹配判断。
Class WeChat.Message.SendResponse Extends Ens.Response
{

/// 产生此响应的通道: wecomapp 或 wecomrobot。
Property Channel As %String(MAXLEN = 20);

/// 取 accepted / partial / rejected / unknown 之一。
Property Result As %String(MAXLEN = 20);

/// 便捷标志: 仅 accepted 或 partial 时为 true。
Property Success As %Boolean [ InitialExpression = 0 ];

/// 平台 errcode，带符号；报告成功或响应未出现 errcode 时为 0，用 ErrorCodePresent 区分。
Property ErrorCode As %Integer [ InitialExpression = 0 ];

/// 响应体确实携带了 errcode 字段时为 True。消息推送通道没有官方规定的响应体，
/// 空或非 JSON 响应会得到 ErrorCodePresent = 0 且 Result = unknown。
Property ErrorCodePresent As %Boolean [ InitialExpression = 0 ];

/// 我们自己对 ErrorCode 的解释。绝不通过匹配 errmsg 推导：errmsg 可能变化，官方文档禁止这样做。
Property ErrorMessage As %String(MAXLEN = 2000);

/// 平台 errmsg，仅透传用于诊断。
Property RawErrmsg As %String(MAXLEN = 500);

/// 最后一次尝试的 HTTP 状态码，未收到响应时为 0。
Property HttpStatus As %Integer [ InitialExpression = 0 ];

/// 已进行的尝试次数，上限由 adapter 的 MaxAttempts 决定（官方建议 -1 时总共最多尝试 3 次）。
Property Attempts As %Integer [ InitialExpression = 0 ];

/// 当至少一次尝试得到"需刷新 token"的处置答复时为 True。
Property TokenRefreshed As %Boolean [ InitialExpression = 0 ];

/// 整个尝试序列的往返耗时，单位为毫秒。
Property LatencyMs As %Integer [ InitialExpression = 0 ];

// ---- 应用消息部分失败明细 ---------------------------------------------------

/// 平台 msgid，用于撤回应用消息。
Property MessageId As %String(MAXLEN = 200);

/// 仅交互型模板卡片返回，一次性使用（有效期 72 小时）。V1 透传但不消费。
Property ResponseCode As %String(MAXLEN = 200);

/// 无效的 userid。平台会将其转为小写，与请求比较时必须忽略大小写。
Property InvalidUser As %String(MAXLEN = 32767);

Property InvalidParty As %String(MAXLEN = 4000);

Property InvalidTag As %String(MAXLEN = 4000);

/// 可见范围内但没有基础接口许可的 userid。与 InvalidUser 语义不同（接收者
/// 存在且可见，只是没有许可），两者绝不能混用同一条消息。
Property UnlicensedUser As %String(MAXLEN = 32767);

/// 供消息浏览器使用的一行摘要。
Method DisplayText() As %String
{
	Quit ..Result _ " errcode=" _ ..ErrorCode _ $Select(..ErrorMessage '= "":" (" _ $Extract(..ErrorMessage, 1, 120) _ ")", 1:"")
}

Method HasPartialFailure() As %Boolean
{
	Quit (..InvalidUser '= "") || (..InvalidParty '= "") || (..InvalidTag '= "") || (..UnlicensedUser '= "")
}

Method UnlicensedCount() As %Integer
{
	If ..UnlicensedUser = "" Quit 0
	Quit $Length(..UnlicensedUser, "|")
}

Method InvalidUserCount() As %Integer
{
	If ..InvalidUser = "" Quit 0
	Quit $Length(..InvalidUser, "|")
}

}
