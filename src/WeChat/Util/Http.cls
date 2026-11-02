/// 出站适配器共用的 HTTP 辅助方法。
///
/// 凭据脱敏特意放在这里：官方消息推送文档警告，webhook URL 一旦
/// 泄露，任何人都能向群里发消息，因此任何日志行、异常文本或诊断
/// 信息都绝不能携带 webhook key、access token 或 corpsecret。
Class WeChat.Util.Http
{

/// 对值做百分号编码，供查询字符串使用。
ClassMethod UrlEncode(pValue As %String) As %String
{
	Set tBytes = $ZConvert(pValue, "O", "UTF8")
	Set tOut = ""
	For i = 1:1:$Length(tBytes) {
		Set tChar = $Extract(tBytes, i)
		If tChar?.AN || (tChar = "-") || (tChar = "_") || (tChar = ".") || (tChar = "~") {
			Set tOut = tOut _ tChar
		} Else {
			Set tHex = $ZConvert($ZHex($Ascii(tChar)), "U")
			Set tOut = tOut _ "%" _ $Select($Length(tHex) < 2:"0" _ tHex, 1:tHex)
		}
	}
	Quit tOut
}

/// 将携带凭据的查询参数替换为 ***，使 URL 可安全写入日志。
/// 实现为对查询字符串的一次拆分-重建：「查找 name=、替换值、重复」的
/// 循环不会终止——替换后文本中仍含 "key=***"，下一次查找会再次命中并永远替换下去。
ClassMethod RedactUrl(pUrl As %String) As %String
{
	Set tBase = pUrl
	Set tQuery = ""
	Set tFragment = ""
	Set tHash = $Find(pUrl, "#")
	If tHash > 0 {
		Set tFragment = $Extract(pUrl, tHash - 1, *)
		Set tBase = $Extract(pUrl, 1, tHash - 2)
	}
	Set tQ = $Find(tBase, "?")
	If tQ > 0 {
		Set tQuery = $Extract(tBase, tQ, *)
		Set tBase = $Extract(tBase, 1, tQ - 1)
	}
	If tQuery = "" Quit tBase _ tFragment

	Set tSecrets = ",key,access_token,corpsecret,secret,appsecret,token,"
	Set tOut = ""
	Set tCount = $Length(tQuery, "&")
	For i = 1:1:tCount {
		Set tPair = $Piece(tQuery, "&", i)
		Set tEq = $Find(tPair, "=")
		If tEq = 0 {
			Set tPiece = tPair
		} Else {
			Set tName = $ZConvert($Extract(tPair, 1, tEq - 2), "L")
			Set tPiece = $Extract(tPair, 1, tEq - 1) _ $Select($Find(tSecrets, "," _ tName _ ",") > 0:"***", 1:$Extract(tPair, tEq, *))
		}
		Set tOut = tOut _ $Select(i = 1:"", 1:"&") _ tPiece
	}
	Quit tBase _ tOut _ tFragment
}

// ---------------------------------------------------------------- 时间辅助方法

/// 从 $ZTIMESTAMP 值计算自 epoch 起的毫秒数。$ZTIMESTAMP 不是单个十进制数，而是
/// "days,seconds.fraction" 字符串（如 "67876,22888.791144672"），按数值处理会在逗号处
/// 强制转换并静默丢弃天数，曾使耗时测量恒为 0、token TTL 过期无法被发现，故两部分显式解析。
ClassMethod TimestampMs(pStamp As %String) As %Numeric
{
	Set tDays = +$Piece(pStamp, ",", 1)
	Set tSecs = +$Piece(pStamp, ",", 2)
	Quit (tDays * 86400000) + (tSecs * 1000)
}

/// 从 $ZTIMESTAMP 值计算 epoch 秒。
ClassMethod EpochOffset(pStamp As %String) As %Numeric
{
	Set tDays = +$Piece(pStamp, ",", 1)
	Set tSecs = +$Piece(pStamp, ",", 2)
	Quit ((tDays - $ZDATEH("1970-01-01", 3)) * 86400) + tSecs
}

/// 「当前时刻」的整数 epoch 秒，用于 token 过期记录。
/// 显式截断：%Integer 只在 %Save 时才做转换，否则未落盘的返回值
/// 会把小数部分带进每一次比较。
ClassMethod EpochNow() As %Integer
{
	Quit ..EpochOffset($ZTIMESTAMP) \ 1
}

/// 自 $ZTIMESTAMP 起始值以来经过的毫秒数。结果永不为负，因此即使
/// 时钟被调整，调用方也不会看到不可能的延迟值。
ClassMethod ElapsedMs(pStart As %String, pEnd As %String = "") As %Integer
{
	Set tEnd = $Select(pEnd '= "":pEnd, 1:$ZTIMESTAMP)
	Set tMs = ..TimestampMs(tEnd) - ..TimestampMs(pStart)
	If tMs < 0 Set tMs = 0
	// 显式取整：%Integer 只在 %Save 时才截断，否则未落盘的
	// SendResponse 会上报带小数的延迟。
	Quit tMs \ 1
}

/// 状态码对应的原因短语，仅涵盖 V1 实际可能收到的状态码。
ClassMethod Reason(pStatus As %Integer) As %String
{
	Quit $Case(pStatus,
		200:"OK", 204:"No Content", 400:"Bad Request", 401:"Unauthorized",
		403:"Forbidden", 404:"Not Found", 429:"Too Many Requests",
		500:"Internal Server Error", 502:"Bad Gateway", 503:"Service Unavailable",
		504:"Gateway Timeout",
		:"Status " _ pStatus)
}

}
