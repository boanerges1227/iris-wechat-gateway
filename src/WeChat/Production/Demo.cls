/// V1 的演示 production：仅包含两个出站 Business Operation。
/// 出厂时带有官方 API base URL 和空的凭据占位值，因此可以干净启动，
/// 但在配置你自己的值之前无法发送。V1 按设计没有入站组件：没有 webhook
/// 监听器、没有 callback token、没有 EncodingAESKey，也没有 XML 或 AES 工具。
/// 要使用真实账号，请编辑下方 production 设置（或在你自己的 production 中配置
/// 各 BO）。真实的 webhook key 或 corpsecret 必须放入 Interoperability 凭据
/// （`RobotKeyCredential` / `SecretCredential`），而不是字面量设置。
Class WeChat.Production.Demo Extends Ens.Production
{

XData ProductionDefinition
{
<Production Name="WeChat.Production.Demo" LogGeneralTraceEvents="false">
  <Description>WeCom 网关演示（应用消息 + 消息推送）</Description>
  <ActorPoolSize>4</ActorPoolSize>
  <Item Name="SendWeComApp" Category="" ClassName="WeChat.BO.SendMessageWeComApp" PoolSize="1" Enabled="true" Foreground="false" Comment="出站 WeCom 应用消息" LogTraceEvents="false" Schedule="">
    <Setting Target="Adapter" Name="ApiBaseUrl">https://qyapi.weixin.qq.com</Setting>
    <Setting Target="Adapter" Name="CorpId"></Setting>
    <Setting Target="Adapter" Name="CorpSecret"></Setting>
    <Setting Target="Adapter" Name="AgentId">1000002</Setting>
    <Setting Target="Adapter" Name="Timeout">10</Setting>
    <Setting Target="Adapter" Name="MaxAttempts">3</Setting>
    <Setting Target="Adapter" Name="RetryBaseSeconds">1</Setting>
    <Setting Target="Adapter" Name="RetryOnThrottle">0</Setting>
    <Setting Target="Adapter" Name="ThrottleWaitSeconds">60</Setting>
  </Item>
  <Item Name="SendWeComRobot" Category="" ClassName="WeChat.BO.SendMessageWeComRobot" PoolSize="1" Enabled="true" Foreground="false" Comment="出站 WeCom 消息推送（群机器人）" LogTraceEvents="false" Schedule="">
    <Setting Target="Adapter" Name="ApiBaseUrl">https://qyapi.weixin.qq.com</Setting>
    <Setting Target="Adapter" Name="RobotKey"></Setting>
    <Setting Target="Adapter" Name="Timeout">10</Setting>
    <Setting Target="Adapter" Name="MaxAttempts">3</Setting>
    <Setting Target="Adapter" Name="RetryBaseSeconds">1</Setting>
    <Setting Target="Adapter" Name="RetryOnThrottle">0</Setting>
    <Setting Target="Adapter" Name="ThrottleWaitSeconds">60</Setting>
    <Setting Target="Adapter" Name="TreatEmptyBodyAsAccepted">0</Setting>
  </Item>
</Production>
}

}
