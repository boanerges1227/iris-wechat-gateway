/// WeCom 应用消息通道的 Business Operation。
/// 用 CorpId、SecretCredential（优先）或 CorpSecret，以及 AgentId 配置 adapter。
/// secret 与 agentid 必须属于同一个自建应用：通讯录同步助手的 secret 完全无法
/// 发消息（errcode 48002），将 token 用于其他应用的 agentid 会得到 errcode 301002。
/// 支持 msgtype text 和 markdown，两者均限制 2048 字节。
/// 官方原文："每应用对同一个成员不可超过30次/分钟，1000次/小时，超过部分会被丢弃不下发"——超出即静默丢弃，受理不等于送达；V1 未实现客户端限流器，调用方必须自行节流。
/// 出口 IP 必须列入该应用的企业可信IP，新加入的条目需一分钟后才生效（否则 errcode 60020）。
Class WeChat.BO.SendMessageWeComApp Extends WeChat.BO.SendMessageBase
{

Parameter ADAPTER = "WeChat.Adapter.Outbound.WeComApp";

}
