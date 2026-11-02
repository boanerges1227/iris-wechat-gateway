/// 用于微信负载校验的、按字节精确计算的文本辅助方法。
///
/// WeCom 官方限制以字节计（应用 text 2048B、应用 markdown 2048B、消息推送 text
/// 2048B、消息推送 markdown 4096B）。$Length() 统计的是 UTF-16 码元，既不是字符数
/// 也不是字节数：在 irishealth-community:2026.2 上实测，$Length("abc中🎉") 返回 6
/// 而不是 5，因为 U+1F389 位于 BMP 之外。因此所有长度校验都必须经过 ByteLength()。
Class WeChat.Util.Text
{

/// pText 的 UTF-8 字节长度。对照官方限制度量消息时，这是唯一正确的做法。
ClassMethod ByteLength(pText As %String) As %Integer
{
	Quit $Length($ZConvert(pText, "O", "UTF8"))
}

/// 当 pText 能容纳在 pMaxBytes 个 UTF-8 字节内时返回 True。
ClassMethod FitsBytes(pText As %String, pMaxBytes As %Integer) As %Boolean
{
	Quit ..ByteLength(pText) <= pMaxBytes
}

/// pText 开头能容纳在 pMaxBytes 个 UTF-8 字节内的字符个数。仅用于诊断以及任何
/// 未来可选启用的拆分功能：按原始字节偏移截断会拆断多字节字符（2048 不是 3 的
/// 倍数，因此在限制处截断的 CJK 消息必然损坏）。
ClassMethod CharsWithinBytes(pText As %String, pMaxBytes As %Integer) As %Integer
{
	Set tTotal = $Length(pText)
	Set tLow = 0
	Set tHigh = tTotal
	While tLow < tHigh {
		Set tMid = (tLow + tHigh + 1) \ 2
		If ..ByteLength($Extract(pText, 1, tMid)) <= pMaxBytes {
			Set tLow = tMid
		} Else {
			Set tHigh = tMid - 1
		}
	}
	Quit tLow
}

/// 当解码后的值包含字面量反斜杠-u 转义（如 \u4f60）时返回 True。官方 errcode
/// 40033 的文案为 "illegal request character, cannot contain \uxxxx format
/// characters"；它针对的是这一字面量序列还是 JSON 传输编码，官方文档并未说明，
/// 且 %ToJSON() 不会输出 Unicode 转义。保留此检测仅用于诊断，绝不用于静默改写内容。
ClassMethod HasLiteralUnicodeEscape(pText As %String) As %Boolean
{
	// 在循环块内带值 QUIT 是非法的（<COMMAND>），因此结果
	// 累积在标志变量中，待循环结束后一次性返回。
	Set tFound = 0
	Set tPos = 1
	While 'tFound {
		Set tPos = $Find(pText, "\u", tPos)
		If tPos = 0 Quit
		Set tHex = $Extract(pText, tPos, tPos + 3)
		If $Length(tHex) = 4 {
			Set tAllHex = 1
			For i = 1:1:4 {
				Set tChar = $Extract(tHex, i)
				If (tChar '? 1N) && ((tChar < "A") || (tChar > "F")) && ((tChar < "a") || (tChar > "f")) Set tAllHex = 0
			}
			If tAllHex Set tFound = 1
		}
	}
	Quit tFound
}

/// 当字符串包含 WeCom 文档规定为请求内容中非法的字符时返回
/// True，用于在平台拒绝之前进行本地诊断。
ClassMethod HasControlChars(pText As %String) As %Boolean
{
	Set tFound = 0
	Set tLen = $Length(pText)
	For i = 1:1:tLen {
		Set tCode = $Ascii(pText, i)
		// tab、LF 和 CR 是合法的（官方文本内容支持 \n）
		If (tCode < 32) && (tCode '= 9) && (tCode '= 10) && (tCode '= 13) Set tFound = 1
	}
	Quit tFound
}

}
