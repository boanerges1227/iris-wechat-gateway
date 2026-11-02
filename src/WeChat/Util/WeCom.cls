/// 两个 V1 渠道的企业微信消息体构建与校验。
///
/// 校验在本地进行且严格，因为平台自身的行为不一致且部分无记载：
///   * 应用渠道 text 超过 2048 字节时官方行为是截断，而 2048 不是 3 的
///     倍数，截断会把 CJK 字符切成乱码；
///   * 对其余所有（渠道, msgtype）组合，超长行为完全没有文档记载。
/// 因此客户端拒绝超长内容是唯一安全的选择，长度按 UTF-8 字节度量。
Class WeChat.Util.WeCom
{

Parameter CHANNELAPP = "wecomapp";
Parameter CHANNELROBOT = "wecomrobot";

/// 官方字节上限，按渠道和消息类型区分。各渠道之间不可混用：
/// 应用渠道 markdown 为 2048，而消息推送 markdown 为 4096。
ClassMethod ContentLimit(pChannel As %String, pMsgType As %String) As %Integer
{
	Set tChannel = $ZConvert(pChannel, "L")
	Set tType = $ZConvert(pMsgType, "L")
	If tChannel = ..#CHANNELAPP {
		Quit $Case(tType, "text":2048, "markdown":2048, :-1)
	}
	If tChannel = ..#CHANNELROBOT {
		Quit $Case(tType, "text":2048, "markdown":4096, "markdown_v2":4096, :-1)
	}
	Quit -1
}

/// 应用渠道的官方收件人列表上限。
ClassMethod RecipientLimit(pField As %String) As %Integer
{
	Quit $Case($ZConvert(pField, "L"), "touser":1000, "toparty":100, "totag":100, :-1)
}

/// duplicate_check_interval 的官方最大值：4 小时。
ClassMethod MaxDuplicateCheckInterval() As %Integer
{
	Quit 14400
}

/// 按声明的渠道校验出站请求。
/// 返回 $$$OK，或返回带有运维人员可据以处理的消息的 status。
ClassMethod Validate(pRequest As WeChat.Message.Outbound) As %Status
{
	If '$IsObject(pRequest) Quit $$$ERROR($$$GeneralError, "Missing outbound request")

	Set tChannel = $ZConvert(pRequest.Channel, "L")
	If (tChannel '= ..#CHANNELAPP) && (tChannel '= ..#CHANNELROBOT) {
		Quit $$$ERROR($$$GeneralError, "Unknown Channel '"_pRequest.Channel_"'; expected "_..#CHANNELAPP_" or "_..#CHANNELROBOT)
	}

	Set tType = $ZConvert(pRequest.MsgType, "L")
	If tType = "markdown_v2" {
		// 显式拒绝，绝不静默降级：markdown_v2 语法子集支持表格、列表和围栏代码，
		// 但不支持字体颜色，若按 markdown 渲染会在客户端产生原始标点符号。
		Quit $$$ERROR($$$GeneralError, "markdown_v2 is not supported in V1; it exists only on the "_..#CHANNELROBOT_" channel and is not syntax-compatible with markdown")
	}
	If (tType '= "text") && (tType '= "markdown") {
		Quit $$$ERROR($$$GeneralError, "Unsupported MsgType '"_pRequest.MsgType_"'; V1 supports text and markdown")
	}

	Set tLimit = ..ContentLimit(tChannel, tType)
	If tLimit < 0 {
		Quit $$$ERROR($$$GeneralError, "No content limit defined for "_tChannel_"/"_tType)
	}
	If pRequest.Content = "" {
		Quit $$$ERROR($$$GeneralError, "Content is required (platform errcode 44004 for application text)")
	}
	Set tBytes = ##class(WeChat.Util.Text).ByteLength(pRequest.Content)
	If tBytes > tLimit {
		Quit $$$ERROR($$$GeneralError, "Content is "_tBytes_" UTF-8 bytes, over the "_tLimit_"-byte limit for "_tChannel_" "_tType_". Refusing to send: the platform truncates application text at a byte offset that can split a multi-byte character, and over-length behaviour is undocumented for the other types.")
	}

	If tChannel = ..#CHANNELAPP Quit ..ValidateApp(pRequest, tType)
	Quit ..ValidateRobot(pRequest, tType)
}

/// 应用渠道校验：收件人、agentid 和字段矩阵。
ClassMethod ValidateApp(pRequest As WeChat.Message.Outbound, pMsgType As %String) As %Status
{
	// touser / toparty / totag 不能全为空（errcode 81012 / 82001）。
	If (pRequest.ToUser = "") && (pRequest.ToParty = "") && (pRequest.ToTag = "") {
		Quit $$$ERROR($$$GeneralError, "At least one of ToUser, ToParty or ToTag is required (platform errcode 81012)")
	}

	Set tSC = ..ValidateIdList(pRequest.ToUser, "touser")
	Quit:$$$ISERR(tSC) tSC
	Set tSC = ..ValidateIdList(pRequest.ToParty, "toparty")
	Quit:$$$ISERR(tSC) tSC
	Set tSC = ..ValidateIdList(pRequest.ToTag, "totag")
	Quit:$$$ISERR(tSC) tSC

	If (pRequest.AgentId = "") || (pRequest.AgentId <= 0) {
		Quit $$$ERROR($$$GeneralError, "AgentId is required and must be a positive integer (platform errcode 41011 / 40056)")
	}

	// 官方规定 markdown 既没有 `safe` 也没有 `enable_id_trans`。将其报告为
	// 错误是有意为之：静默丢弃该字段会让调用方误以为保密消息已明文发出。
	If pMsgType = "markdown" {
		If pRequest.Safe '= 0 {
			Quit $$$ERROR($$$GeneralError, "Safe is not a valid field for application markdown messages; it is documented for text only. Refusing rather than silently ignoring it.")
		}
		If pRequest.EnableIdTrans {
			Quit $$$ERROR($$$GeneralError, "EnableIdTrans is not a valid field for application markdown messages; it is documented for text only.")
		}
	}

	// @提醒列表只属于消息推送渠道。
	If pRequest.MentionedList.Count() > 0 {
		Quit $$$ERROR($$$GeneralError, "MentionedList belongs to the "_..#CHANNELROBOT_" channel; the application channel has no such field")
	}
	If pRequest.MentionedMobileList.Count() > 0 {
		Quit $$$ERROR($$$GeneralError, "MentionedMobileList belongs to the "_..#CHANNELROBOT_" channel; the application channel has no such field")
	}

	Set tInterval = pRequest.DuplicateCheckInterval
	If (tInterval < 0) || (tInterval > ..MaxDuplicateCheckInterval()) {
		Quit $$$ERROR($$$GeneralError, "DuplicateCheckInterval must be between 0 and "_..MaxDuplicateCheckInterval()_" seconds (official maximum is 4 hours)")
	}
	Quit $$$OK
}

/// 消息推送校验：该渠道的字段矩阵。
ClassMethod ValidateRobot(pRequest As WeChat.Message.Outbound, pMsgType As %String) As %Status
{
	// 收件人和 agentid 在此渠道没有意义；目标由适配器持有的
	// webhook key 决定。
	If pRequest.ToUser '= "" {
		Quit $$$ERROR($$$GeneralError, "ToUser is not valid on the "_..#CHANNELROBOT_" channel; the target is the configured webhook key")
	}
	If pRequest.ToParty '= "" {
		Quit $$$ERROR($$$GeneralError, "ToParty is not valid on the "_..#CHANNELROBOT_" channel")
	}
	If pRequest.ToTag '= "" {
		Quit $$$ERROR($$$GeneralError, "ToTag is not valid on the "_..#CHANNELROBOT_" channel")
	}
	If pRequest.AgentId '= "" {
		Quit $$$ERROR($$$GeneralError, "AgentId is not valid on the "_..#CHANNELROBOT_" channel")
	}

	// 官方 markdown 字段表没有 mentioned_list / mentioned_mobile_list；
	// 其中的 @提醒需改用 <@userid> 内联语法。
	If pMsgType = "markdown" {
		If pRequest.MentionedList.Count() > 0 {
			Quit $$$ERROR($$$GeneralError, "MentionedList is documented for message push text only. For markdown, mention members with the <@userid> syntax inside Content.")
		}
		If pRequest.MentionedMobileList.Count() > 0 {
			Quit $$$ERROR($$$GeneralError, "MentionedMobileList is documented for message push text only. For markdown, mention members with the <@userid> syntax inside Content.")
		}
	}

	If pRequest.Safe '= 0 {
		Quit $$$ERROR($$$GeneralError, "Safe is not a valid field on the "_..#CHANNELROBOT_" channel")
	}
	If pRequest.EnableIdTrans {
		Quit $$$ERROR($$$GeneralError, "EnableIdTrans is not a valid field on the "_..#CHANNELROBOT_" channel")
	}
	Quit $$$OK
}

/// 按官方数量上限校验以 "|" 分隔的 id 列表。
ClassMethod ValidateIdList(pValue As %String, pField As %String) As %Status
{
	If pValue = "" Quit $$$OK
	Set tLimit = ..RecipientLimit(pField)
	If tLimit < 0 Quit $$$OK
	// "@all" 是 touser 的合法单值，不按列表计数。
	If $ZConvert(pValue, "L") = "@all" {
		If pField = "touser" Quit $$$OK
		Quit $$$ERROR($$$GeneralError, "'@all' is only valid for touser, not for "_pField)
	}
	Set tCount = $Length(pValue, "|")
	If tCount > tLimit {
		Quit $$$ERROR($$$GeneralError, pField_" contains "_tCount_" ids, over the official limit of "_tLimit_" (platform errcode "_$Case(pField,"toparty":82002,"totag":82003,:"40058")_")")
	}
	Set tBlank = 0
	For i = 1:1:tCount {
		If $ZStrip($Piece(pValue, "|", i), "<>W") = "" Set tBlank = 1
	}
	If tBlank {
		Quit $$$ERROR($$$GeneralError, pField_" contains an empty entry; ids are '|' separated with no blank elements")
	}
	Quit $$$OK
}

/// 构建应用消息的请求体。官方字段集随 msgtype 而变，因此只输出有文档记载
/// 的字段；平台对未记载字段的容忍度没有说明。
ClassMethod BuildAppPayload(pRequest As WeChat.Message.Outbound) As %DynamicObject
{
	Set tPayload = {}
	If pRequest.ToUser '= "" Set tPayload.touser = pRequest.ToUser
	If pRequest.ToParty '= "" Set tPayload.toparty = pRequest.ToParty
	If pRequest.ToTag '= "" Set tPayload.totag = pRequest.ToTag
	Set tPayload.msgtype = $ZConvert(pRequest.MsgType, "L")
	Set tPayload.agentid = pRequest.AgentId + 0

	Set tBody = {}
	Set tBody.content = pRequest.Content
	Do tPayload.%Set(tPayload.msgtype, tBody)

	If tPayload.msgtype = "text" {
		Set tPayload.safe = pRequest.Safe + 0
		Do tPayload.%Set("enable_id_trans", $Select(pRequest.EnableIdTrans:1, 1:0))
	}
	If pRequest.EnableDuplicateCheck {
		Do tPayload.%Set("enable_duplicate_check", 1)
		Do tPayload.%Set("duplicate_check_interval", pRequest.DuplicateCheckInterval + 0)
	}
	Quit tPayload
}

/// 构建消息推送的请求体。
ClassMethod BuildRobotPayload(pRequest As WeChat.Message.Outbound) As %DynamicObject
{
	Set tPayload = {}
	Set tPayload.msgtype = $ZConvert(pRequest.MsgType, "L")

	Set tBody = {}
	Set tBody.content = pRequest.Content
	If (tPayload.msgtype = "text") {
		If pRequest.MentionedList.Count() > 0 {
			Set tArr = []
			For i = 1:1:pRequest.MentionedList.Count() {
				Set tItem = pRequest.MentionedList.GetAt(i)
				If tItem '= "" Do tArr.%Push(tItem)
			}
			Do tBody.%Set("mentioned_list", tArr)
		}
		If pRequest.MentionedMobileList.Count() > 0 {
			Set tArr2 = []
			For i = 1:1:pRequest.MentionedMobileList.Count() {
				Set tItem = pRequest.MentionedMobileList.GetAt(i)
				If tItem '= "" Do tArr2.%Push(tItem)
			}
			Do tBody.%Set("mentioned_mobile_list", tArr2)
		}
	}
	Do tPayload.%Set(tPayload.msgtype, tBody)
	Quit tPayload
}

/// 当 pUserid（不区分大小写）出现在以 "|" 分隔的 pList 中时为真。
ClassMethod InIdList(pList As %String, pUserid As %String) As %Boolean
{
	If pList = "" Quit 0
	Set tTarget = $ZConvert(pUserid, "L")
	Set tFound = 0
	Set tCount = $Length(pList, "|")
	For i = 1:1:tCount {
		If $ZConvert($ZStrip($Piece(pList, "|", i), "<>W"), "L") = tTarget Set tFound = 1
	}
	Quit tFound
}

}
