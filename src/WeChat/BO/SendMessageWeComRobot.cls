/// WeCom 消息推送通道的 Business Operation（前身为 群机器人）。
/// 用 RobotKeyCredential（优先）或 RobotKey 配置 adapter。
/// webhook key 是高风险凭据：一旦泄露，任何人都可以向群里发文，因此它绝不能
/// 出现在源码控制、README 或测试示例中。
/// 支持 msgtype text 和 markdown。官方限制：text 2048 字节，markdown 4096 字节，
/// 每个机器人每分钟最多 20 条；提及列表仅对 text 有效，markdown 须用 <@userid> 内联语法。
Class WeChat.BO.SendMessageWeComRobot Extends WeChat.BO.SendMessageBase
{

Parameter ADAPTER = "WeChat.Adapter.Outbound.WeComRobot";

}
