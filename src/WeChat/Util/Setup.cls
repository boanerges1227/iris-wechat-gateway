/// 安装、演示 production 注册与构建期冒烟检查辅助方法。
Class WeChat.Util.Setup
{

Parameter PRODUCTION = "WeChat.Production.Demo";

/// 安装完成后由 IPM 调用。
ClassMethod Install() As %Status
{
	Do ..EnsureSSLConfig()
	Write !, "iris-wechat-gateway installed."
	Write !, "V1 provides two outbound Business Operations:"
	Write !, "  WeChat.BO.SendMessageWeComApp    application message (corpid + corpsecret + agentid)"
	Write !, "  WeChat.BO.SendMessageWeComRobot  message push, formerly group robot (webhook key)"
	Write !, "Run do ##class(WeChat.Util.Setup).Start() to launch the bundled demo production."
	Write !, "Before using a real account, read the trusted-IP and frequency-limit notes in README."
	Quit $$$OK
}

/// 由 IPM 和 Docker 构建调用。
ClassMethod Setup() As %Status
{
	Set tSC = $$$OK
	Try {
		Do ..EnsureSSLConfig()
		Set ^Ens.AutoStart = ..#PRODUCTION
		Set ^Ens.AutoStart("StartupPriority") = 1
		If '$Data(^Ens.Configuration("csp", "LastProduction")) {
			Set ^Ens.Configuration("csp", "LastProduction") = ..#PRODUCTION
		}
		Write !, "WeCom demo production registered for auto-start."
	} Catch ex {
		Set tSC = ex.AsStatus()
	}
	Quit tSC
}

/// 构建期间验证 production 能启动与停止，失败状态向上传递。
ClassMethod Smoke() As %Status
{
	Set tSC = ##class(Ens.Director).StartProduction(..#PRODUCTION)
	If $$$ISERR(tSC) {
		Write !, "SMOKE: production did not start: ", $System.Status.GetErrorText(tSC)
		Quit tSC
	}
	Write !, "SMOKE: production started: ", ..Status()
	Set tSC = ##class(Ens.Director).StopProduction(10, 1)
	If $$$ISERR(tSC) {
		Write !, "SMOKE: production did not stop cleanly: ", $System.Status.GetErrorText(tSC)
	}
	Quit tSC
}

/// 尽力创建针对 qyapi.weixin.qq.com 的出站 TLS 配置。
ClassMethod EnsureSSLConfig() As %Status
{
	Set tNamespace = $NAMESPACE
	Set tSC = $$$OK
	Try {
		ZN "%SYS"
		If '$CLASSMETHOD("Security.SSLConfigs", "Exists", "WeChat.SSL") {
			Set tSC = $CLASSMETHOD("Security.SSLConfigs", "Create", "WeChat.SSL")
			If $$$ISERR(tSC) {
				Write !, "NOTE: TLS config WeChat.SSL was not created: ", $System.Status.GetErrorText(tSC)
				Set tSC = $$$OK
			}
		}
	} Catch ex {
		Set tSC = $$$OK
	}
	ZN tNamespace
	Quit tSC
}

ClassMethod Start() As %Status
{
	Set tSC = ##class(Ens.Director).StartProduction(..#PRODUCTION)
	If $$$ISOK(tSC) {
		Set ^Ens.AutoStart = ..#PRODUCTION
		Set ^Ens.AutoStart("StartupPriority") = 1
	}
	Quit tSC
}

ClassMethod Stop() As %Status
{
	Quit ##class(Ens.Director).StopProduction(10, 1)
}

ClassMethod Status() As %String
{
	Set tProduction = ""
	Set tState = ""
	Set tSC = ##class(Ens.Director).GetProductionStatus(.tProduction, .tState)
	If $$$ISERR(tSC) Quit "status error: "_$System.Status.GetErrorText(tSC)
	Quit "production="_tProduction_", state="_tState
}

/// 不经 production 直接经 adapter 发送消息推送测试消息。默认无 key，预期得到明确的本地拒绝；绝不打印 key。
ClassMethod SendRobotTest(pText As %String = "Hello from IRIS 你好 🎉", pMsgType As %String = "text", pBaseUrl As %String = "https://qyapi.weixin.qq.com", pKey As %String = "") As %Status
{
	Set tAdapter = ##class(WeChat.Adapter.Outbound.WeComRobot).%New()
	Set tAdapter.ApiBaseUrl = pBaseUrl
	Set tAdapter.RobotKey = pKey
	Set tAdapter.Timeout = 10
	Set tRequest = ##class(WeChat.Message.Outbound).%New()
	Set tRequest.Channel = "wecomrobot"
	Set tRequest.MsgType = pMsgType
	Set tRequest.Content = pText
	Set tResponse = ""
	Set tSC = tAdapter.Send(tRequest, .tResponse)
	Do ..Report(tResponse)
	Quit tSC
}

/// 不经 production 直接经 adapter 发送应用消息测试。默认无凭据，预期得到明确的本地拒绝。
ClassMethod SendAppTest(pToUser As %String = "zhangsan", pText As %String = "Hello from IRIS 你好 🎉", pMsgType As %String = "text", pBaseUrl As %String = "https://qyapi.weixin.qq.com", pCorpId As %String = "", pSecret As %String = "", pAgentId As %Integer = 1000002) As %Status
{
	Set tAdapter = ##class(WeChat.Adapter.Outbound.WeComApp).%New()
	Set tAdapter.ApiBaseUrl = pBaseUrl
	Set tAdapter.CorpId = pCorpId
	Set tAdapter.CorpSecret = pSecret
	Set tAdapter.AgentId = pAgentId
	Set tAdapter.Timeout = 10
	Set tRequest = ##class(WeChat.Message.Outbound).%New()
	Set tRequest.Channel = "wecomapp"
	Set tRequest.MsgType = pMsgType
	Set tRequest.Content = pText
	Set tRequest.ToUser = pToUser
	Set tRequest.AgentId = pAgentId
	Set tResponse = ""
	Set tSC = tAdapter.Send(tRequest, .tResponse)
	Do ..Report(tResponse)
	Quit tSC
}

/// 打印脱敏后的结果摘要。绝不打印凭据或响应体。
ClassMethod Report(pResponse As WeChat.Message.SendResponse)
{
	If '$IsObject(pResponse) {
		Write !, "no response object"
		Quit
	}
	Write !, "result=", pResponse.Result, " success=", pResponse.Success, " channel=", pResponse.Channel
	Write !, "http=", pResponse.HttpStatus, " errcode=", pResponse.ErrorCode, " errcodePresent=", pResponse.ErrorCodePresent
	Write !, "attempts=", pResponse.Attempts, " latencyMs=", pResponse.LatencyMs, " tokenRefreshed=", pResponse.TokenRefreshed
	If pResponse.MessageId '= "" Write !, "msgid=", pResponse.MessageId
	If pResponse.HasPartialFailure() {
		Write !, "partial: invaliduser=", pResponse.InvalidUser, " invalidparty=", pResponse.InvalidParty, " invalidtag=", pResponse.InvalidTag
		Write !, "         unlicenseduser=", pResponse.UnlicensedUser
	}
	If pResponse.ErrorMessage '= "" Write !, "message=", pResponse.ErrorMessage
}

/// 容器健康检查。V1 没有入站监听器，健康状态即演示 production 是否正在运行。
ClassMethod Healthy() As %Boolean
{
	Set tName = ""
	Set tState = ""
	Set tSC = ##class(Ens.Director).GetProductionStatus(.tName, .tState)
	If $$$ISERR(tSC) Quit 0
	Quit (tName = ..#PRODUCTION) && (tState = 1)
}

}
