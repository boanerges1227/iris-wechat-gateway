/// WeCom 出站通道共享的 Business Operation 行为。
///
/// BO 刻意做得很薄：传输、errcode 分类、重试上限和 token 处理全部放在
/// adapter 中，因此 BP、BO 或直接调用 adapter 都能获得相同行为。
/// 即使失败也始终返回 SendResponse：调用方需要四态结果，尤其 "unknown"
/// 意味着消息可能已送达，只有调用方能决定是否补偿。
/// Channel 解析放在类方法而非实例内联，以便脱离 production 单测。
Class WeChat.BO.SendMessageBase Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

XData MessageMap
{
<MapItems>
  <MapItem MessageType="WeChat.Message.Outbound">
    <Method>SendMessage</Method>
  </MapItem>
</MapItems>
}

/// 空 Channel 由 adapter 盖章填入，一个请求类因此可面向任一 Business Operation；
/// 非空且与 adapter 不一致时拒绝而非静默改道——两通道的凭据、字节限制和字段集
/// 各不相同，误投的消息会在平台侧以令人困惑的方式失败。
ClassMethod ResolveChannel(ByRef pRequest As WeChat.Message.Outbound, pAdapterChannel As %String, Output pResponse As WeChat.Message.SendResponse) As %Status
{
	If '$IsObject(pRequest) {
		Set pResponse = ..RejectedResponse(pAdapterChannel, "No outbound request supplied")
		Quit $$$ERROR($$$GeneralError, "No outbound request supplied")
	}
	If pRequest.Channel = "" {
		Set pRequest.Channel = pAdapterChannel
		Quit $$$OK
	}
	If $ZConvert(pRequest.Channel, "L") '= $ZConvert(pAdapterChannel, "L") {
		Set tMessage = "Request Channel '" _ pRequest.Channel _ "' cannot be sent by the " _ pAdapterChannel _ " Business Operation"
		Set pResponse = ..RejectedResponse(pAdapterChannel, tMessage)
		Quit $$$ERROR($$$GeneralError, tMessage)
	}
	Quit $$$OK
}

/// 构造 rejected 的 SendResponse，使每条提前退出路径都返回可用对象。
ClassMethod RejectedResponse(pChannel As %String, pMessage As %String) As WeChat.Message.SendResponse
{
	Set tResponse = ##class(WeChat.Message.SendResponse).%New()
	Set tResponse.Channel = pChannel
	Set tResponse.Result = ##class(WeChat.Util.Errors).#RESULTREJECTED
	Set tResponse.ErrorMessage = pMessage
	Quit tResponse
}

Method SendMessage(pRequest As WeChat.Message.Outbound, Output pResponse As WeChat.Message.SendResponse) As %Status
{
	Set tSC = ..ResolveChannel(pRequest, ..Adapter.ChannelName(), .pResponse)
	If $$$ISERR(tSC) Quit tSC

	Set tSC = ..Adapter.Send(pRequest, .pResponse)
	If '$IsObject(pResponse) {
		Set pResponse = ##class(WeChat.Message.SendResponse).%New()
		Set pResponse.Result = ##class(WeChat.Util.Errors).#RESULTUNKNOWN
		Set pResponse.ErrorMessage = "Adapter returned no response object"
	}
	Quit tSC
}

}
