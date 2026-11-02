/// 企业微信消息推送渠道的出站 adapter（旧称"群机器人"）。
/// POST https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key={KEY}，仅依赖 webhook key，不使用 access_token。
/// 官方页面无可信IP / IP白名单字样；是否仍受 IP 限制需在真实账号上确认，并非已证实的豁免。
/// 官方未定义此端点的响应体，缺少 errcode 时的结果分类属于工程决策（参见 WeChat.Adapter.Outbound.Base.Classify 和 TreatEmptyBodyAsAccepted）。
/// 官方限额：text 2048 字节、markdown 4096 字节、每机器人每分钟 20 条；超限后果无文档，网关假定返回 45009 且默认不重试。
/// key 是高风险凭证。官方原文："一定要保护好消息推送的
/// webhook地址，避免泄漏！不要分享到github、博客等可被公开查阅的地方"。
/// 给定凭证 id 时从 Interoperability 凭证解析，所有进入日志行的 URL 都经过 RedactUrl() 脱敏。
Class WeChat.Adapter.Outbound.WeComRobot Extends WeChat.Adapter.Outbound.Base
{

Parameter SETTINGS = "RobotKey:Basic,RobotKeyCredential:Basic,ApiBaseUrl:Basic,SSLConfig:Basic,Timeout:Basic,MaxAttempts:Basic,RetryBaseSeconds:Basic,RetryOnThrottle:Basic,ThrottleWaitSeconds:Basic,TreatEmptyBodyAsAccepted:Basic";

/// 明文 webhook key。优先使用 RobotKeyCredential。
Property RobotKey As %String(MAXLEN = 300);

/// Password 字段存放 webhook key 的凭证 id。
Property RobotKeyCredential As %String(MAXLEN = 100);

Method ChannelName() As %String
{
	Quit "wecomrobot"
}

Method DefaultBaseUrl() As %String
{
	Quit "https://qyapi.weixin.qq.com"
}

Method ValidateConfig() As %Status
{
	If ..GetKey() = "" {
		Quit $$$ERROR($$$GeneralError, "The message push adapter requires RobotKey or RobotKeyCredential. Obtain the key from the message push detail page; never commit it.")
	}
	Quit $$$OK
}

Method RequestPath() As %String
{
	Quit "/cgi-bin/webhook/send"
}

/// 查询字符串携带凭证，因此绝不能未经脱敏就写入日志。
Method RequestQuery(pRequest As WeChat.Message.Outbound) As %String
{
	Quit "key=" _ ##class(WeChat.Util.Http).UrlEncode(..GetKey())
}

Method BuildPayload(pRequest As WeChat.Message.Outbound) As %DynamicObject
{
	Quit ##class(WeChat.Util.WeCom).BuildRobotPayload(pRequest)
}

Method OnInit() As %Status
{
	Set tSC = ##super()
	Quit tSC
}

Method GetKey() As %String
{
	Quit ##class(WeChat.Util.Credentials).Get(..RobotKeyCredential, ..RobotKey)
}

}
