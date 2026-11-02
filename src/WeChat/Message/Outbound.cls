/// V1 所支持 WeCom 通道的通道中立出站消息：一个请求对象同时服务两个通道，
/// 字段对其 (channel, msgtype) 组合是否合法由各 adapter 校验。
/// 字段可用性随通道与类型而异，不应扁平化为宽松的统一 schema：官方规定
/// 应用 markdown 没有 `safe` 和 `enable_id_trans`，消息推送 markdown 没有 `mentioned_list`。
Class WeChat.Message.Outbound Extends Ens.Request
{

/// 目标通道: "wecomapp"（应用消息）或 "wecomrobot"（消息推送）。
Property Channel As %String(MAXLEN = 20);

/// 消息类型: "text" 或 "markdown"。"markdown_v2" 仅存在于消息推送通道且语法子集
/// 不兼容，V1 对其显式拒绝而非静默降级——降级后的表格会渲染成一堆原始标点。
Property MsgType As %String(MAXLEN = 20);

/// 消息正文。官方字节限制：应用 text 2048、应用 markdown 2048、
/// 消息推送 text 2048、消息推送 markdown 4096；按 UTF-8 字节校验
/// （WeChat.Util.Text.ByteLength），$Length() 数的是 UTF-16 码元，不能用于此。
Property Content As %String(MAXLEN = 32767);

// ---- 仅应用消息通道 ---------------------------------------------------------

/// 接收人 userid 列表，以 "|" 分隔，最多 1000 个。"@all" 发给应用全部成员，
/// 此时平台忽略 ToParty 和 ToTag；三者不能全为空。
Property ToUser As %String(MAXLEN = 32767);

/// 接收部门 id 列表，以 "|" 分隔，最多 100 个。
Property ToParty As %String(MAXLEN = 4000);

/// 接收标签 id 列表，以 "|" 分隔，最多 100 个。
Property ToTag As %String(MAXLEN = 4000);

/// 应用 id，整数。必须与所配置的 corpsecret 属于同一个自建应用，不匹配必然导致 errcode 301002。
Property AgentId As %Integer;

/// 保密消息标志，按官方规定仅对 text 有效：0 = 可转发，1 = 不可转发且带水印。默认 0。
Property Safe As %Integer [ InitialExpression = 0 ];

/// 启用 userid/部门 id 转换，按官方规定仅对 text 有效。默认 0。
Property EnableIdTrans As %Boolean [ InitialExpression = 0 ];

/// 启用平台的内容查重：平台侧在 DuplicateCheckInterval 窗口内的内容去重，
/// 不是幂等键，也不提供端到端的送达保证。
Property EnableDuplicateCheck As %Boolean [ InitialExpression = 0 ];

/// 查重窗口，单位为秒。官方默认 1800，最长 4 小时。
Property DuplicateCheckInterval As %Integer [ InitialExpression = 1800 ];

// ---- 仅消息推送通道 ---------------------------------------------------------

/// 要 @ 的 userid，"@all" 表示 @ 所有人。按官方规定仅对 text 有效，
/// markdown 须改用 <@userid> 内联语法；官方未给出元素数量上限。
Property MentionedList As list Of %String(MAXLEN = 100);

/// 要 @ 的手机号，"@all" 表示 @ 所有人。按官方规定仅对 text 有效。
Property MentionedMobileList As list Of %String(MAXLEN = 100);

/// 供消息浏览器使用的一行摘要。绝不包含凭据或完整正文。
Method DisplayText() As %String
{
	Set tPreview = $Extract(..Content, 1, 40)
	If ..Channel = "wecomapp" {
		Set tTo = $Select(..ToUser '= "":..ToUser, ..ToParty '= "":"party:" _ ..ToParty, ..ToTag '= "":"tag:" _ ..ToTag, 1:"?")
		Quit "[" _ ..MsgType _ " app agentid=" _ ..AgentId _ " to=" _ tTo _ "] " _ tPreview
	}
	Quit "[" _ ..MsgType _ " push] " _ tPreview
}

Method IsApp() As %Boolean
{
	Quit $ZConvert(..Channel, "L") = "wecomapp"
}

Method IsRobot() As %Boolean
{
	Quit $ZConvert(..Channel, "L") = "wecomrobot"
}

}
