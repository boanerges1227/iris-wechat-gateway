/// 从 Interoperability Credentials 解析 secret，失败时回退到字面量设置。
/// 显式指定的凭据 id 不存在时返回 "" 而不是回退：运维明确要求使用凭据时
/// 静默改用字面量会掩盖配置错误；对 WeCom 应用通道，错误的 secret 尤其
/// 危险——官方 45009 排障文案称 secret 反复失败会导致来源 IP 被封禁一小时。
Class WeChat.Util.Credentials
{

/// 只解析显式指定的凭据；失败时返回空值，而不是绕过配置。
ClassMethod Get(pCredentialID As %String, pLiteral As %String) As %String
{
	If pCredentialID '= "" {
		Try {
			If '##class(Ens.Config.Credentials).%ExistsId($ZConvert(pCredentialID, "L")) {
				Return ""
			}
			Return ##class(Ens.Config.Credentials).GetValue(pCredentialID, "Password")
		} Catch ex {
			Return ""
		}
	}
	Quit pLiteral
}

/// 凭据的 Username 部分，用于 corpid——运维把两半存放在同一凭据条目时使用。
ClassMethod GetUser(pCredentialID As %String, pLiteral As %String) As %String
{
	If pCredentialID '= "" {
		Try {
			If '##class(Ens.Config.Credentials).%ExistsId($ZConvert(pCredentialID, "L")) {
				Return ""
			}
			Return ##class(Ens.Config.Credentials).GetValue(pCredentialID, "UserName")
		} Catch ex {
			Return ""
		}
	}
	Quit pLiteral
}

/// secret 的指纹，供 token 缓存察觉轮换与日志使用；绝不返回 secret 本身。
ClassMethod Fingerprint(pSecret As %String) As %String
{
	If pSecret = "" Quit ""
	Set tHash = $SYSTEM.Encryption.SHAHash(256, $ZConvert(pSecret, "O", "UTF8"))
	Set tHex = ""
	For i = 1:1:4 {
		Set tByteHex = $ZConvert($ZHex($Ascii(tHash, i)), "U")
		Set tHex = tHex _ $Select($Length(tByteHex) < 2:"0" _ tByteHex, 1:tByteHex)
	}
	Quit $Extract(tHex, 1, 8)
}

}
